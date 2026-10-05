import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

/// Records Apple Log as 10-bit HEVC at the exact average bitrate chosen on the
/// compression slider, encoded live while recording.
///
/// iPhone's built-in movie recorder does not offer HEVC for Apple Log formats
/// and falls back to ProRes (~500 Mbps), so this writer takes the camera's own
/// 10-bit Log frames and encodes them with AVAssetWriter instead. The file is
/// written in 2-second movie fragments, so a crash, call or dead battery still
/// leaves a playable file on disk.
///
/// No colour-properties key is set: the encoder carries the colour attachments
/// that the capture buffers already have, so the Log tagging comes from the
/// camera rather than from this code.
final class LogHEVCWriter: @unchecked Sendable {
    enum WriterError: Error { case cannotAddVideo, cannotStart }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let gainFactor: Float
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var failureReported = false
    private var droppedVideoFrames = 0

    /// Called once, on the main queue, if the writer fails mid-take.
    var onFailure: (() -> Void)?

    init(url: URL, width: Int, height: Int, fps: Int, bitrate: Int, rotationAngle: CGFloat,
         audioChannels: Int, audioSampleRate: Double, gainDb: Double,
         recommended: [String: Any]? = nil) throws {
        self.url = url
        self.gainFactor = abs(gainDb) >= 0.25 ? Float(AudioGain.factor(db: gainDb)) : 1

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let frameRate = max(1, fps)
        // Start from the camera's own recommended HEVC settings for these
        // exact Log frames (they carry the matching colour properties the
        // encoder needs), then force our size, profile and bitrate on top.
        var compression = (recommended?[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]
        compression[AVVideoAverageBitRateKey] = bitrate
        compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        compression[AVVideoExpectedSourceFrameRateKey] = frameRate
        compression[AVVideoMaxKeyFrameIntervalKey] = frameRate
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        if let color = recommended?[AVVideoColorPropertiesKey] {
            videoSettings[AVVideoColorPropertiesKey] = color
        }
        NSLog("[LiveHEVC] writer settings: \(videoSettings)")
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        // Same orientation the movie recorder writes: a track transform, so
        // the pixels themselves are never rotated.
        video.transform = CGAffineTransform(rotationAngle: rotationAngle * .pi / 180)
        guard writer.canAdd(video) else { throw WriterError.cannotAddVideo }
        writer.add(video)

        let channels = max(1, min(2, audioChannels))
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate > 0 ? audioSampleRate : 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 256_000 : 128_000
        ])
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) {
            writer.add(audio)
            audioInput = audio
        } else {
            audioInput = nil
        }

        self.writer = writer
        self.videoInput = video
        guard writer.startWriting() else { throw writer.error ?? WriterError.cannotStart }
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        guard writer.status == .writing else { reportFailure(); return }
        if !started {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            started = true
        }
        if videoInput.isReadyForMoreMediaData {
            if !videoInput.append(buffer) { reportFailure() }
        } else {
            droppedVideoFrames += 1
            if droppedVideoFrames % 30 == 1 {
                NSLog("[LiveHEVC] encoder busy, dropped \(droppedVideoFrames) frame(s)")
            }
        }
    }

    func appendAudio(_ buffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, started, let audioInput, writer.status == .writing,
              audioInput.isReadyForMoreMediaData else { return }
        let out = gainFactor == 1 ? buffer : (Self.scaled(buffer, by: gainFactor) ?? buffer)
        _ = audioInput.append(out)
    }

    /// Closes the file. `completion` is called with true when the writer
    /// reports a completed file.
    func finish(_ completion: @escaping (Bool, Error?) -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let hadFrames = started
        if writer.status == .writing {
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
        }
        lock.unlock()
        NSLog("[LiveHEVC] closing \(url.lastPathComponent), dropped frames: \(droppedVideoFrames)")

        guard hadFrames, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            completion(false, writer.error)
            return
        }
        let writer = self.writer
        writer.finishWriting {
            completion(writer.status == .completed, writer.error)
        }
    }

    /// Called with the lock held.
    private func reportFailure() {
        guard !failureReported else { return }
        failureReported = true
        let ns = writer.error as NSError?
        NSLog("[LiveHEVC] writer failed: \(ns?.localizedDescription ?? "unknown") code=\(ns?.code ?? 0) underlying=\(String(describing: ns?.userInfo[NSUnderlyingErrorKey]))")
        let handler = onFailure
        DispatchQueue.main.async { handler?() }
    }

    /// A copy of a linear-PCM buffer with the manual trim applied. Returns nil
    /// for any format it does not understand, so the caller keeps the original.
    private static func scaled(_ buffer: CMSampleBuffer, by factor: Float) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              let source = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let length = CMBlockBufferGetDataLength(source)
        guard length > 0 else { return nil }

        var copy: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: length, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &copy) == noErr,
              let copy else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(copy, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer,
              CMBlockBufferCopyDataBytes(source, atOffset: 0, dataLength: length,
                                         destination: pointer) == noErr else { return nil }

        let raw = UnsafeMutableRawPointer(pointer)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        if isFloat && asbd.mBitsPerChannel == 32 {
            let n = length / MemoryLayout<Float32>.size
            let samples = raw.bindMemory(to: Float32.self, capacity: n)
            for i in 0..<n { samples[i] = max(-1, min(1, samples[i] * factor)) }
        } else if !isFloat && asbd.mBitsPerChannel == 16 {
            let n = length / MemoryLayout<Int16>.size
            let samples = raw.bindMemory(to: Int16.self, capacity: n)
            for i in 0..<n {
                let v = Float(samples[i]) * factor
                samples[i] = Int16(max(-32768, min(32767, v)))
            }
        } else if !isFloat && asbd.mBitsPerChannel == 32 {
            let n = length / MemoryLayout<Int32>.size
            let samples = raw.bindMemory(to: Int32.self, capacity: n)
            for i in 0..<n {
                let v = Double(samples[i]) * Double(factor)
                samples[i] = Int32(max(-2_147_483_648, min(2_147_483_647, v)))
            }
        } else {
            return nil
        }

        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: copy,
            formatDescription: format,
            sampleCount: CMSampleBufferGetNumSamples(buffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
            packetDescriptions: nil,
            sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}

/// Hands live camera and microphone samples to the active writer, if any.
final class LiveSampleRouter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var writer: LogHEVCWriter?

    func setWriter(_ writer: LogHEVCWriter?) {
        lock.lock(); self.writer = writer; lock.unlock()
    }

    private func current() -> LogHEVCWriter? {
        lock.lock(); defer { lock.unlock() }
        return writer
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        current()?.appendVideo(sampleBuffer)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        current()?.appendAudio(sampleBuffer)
    }
}
