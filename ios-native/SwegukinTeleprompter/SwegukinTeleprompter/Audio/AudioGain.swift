import AVFoundation
import Foundation

/// Manual microphone gain, in decibels, exactly like a camera's audio trim.
///
/// iOS only exposes a hardware gain control for a few inputs; a DJI Mic 2 or any
/// other USB-C interface sets its own level, so `AVAudioSession.setInputGain`
/// does nothing there. The level the user dials in is therefore applied to the
/// audio itself: the meter shows the post-gain level before recording, and the
/// finished take is re-written once with the same factor applied.
///
/// The original file is only replaced after a complete, valid new file exists,
/// so a take can never be lost by this step.
enum AudioGain {
    static let minimumDb: Double = -20
    static let maximumDb: Double = 20

    /// Amplitude multiplier for a decibel trim.
    static func factor(db: Double) -> Double {
        pow(10, db / 20)
    }

    /// The same manual trim expressed as the 0…1 hardware value iOS expects on
    /// the few inputs that expose a gain control. Nothing else ever writes the
    /// hardware gain, so no automatic level can override the chosen setting.
    static func hardwareValue(db: Double) -> Double {
        let clamped = max(minimumDb, min(maximumDb, db))
        return (clamped - minimumDb) / (maximumDb - minimumDb)
    }

    /// Returns the processed file, or the original when nothing was changed or
    /// anything at all went wrong.
    static func apply(gainDb: Double, to url: URL) async -> URL {
        guard abs(gainDb) >= 0.25 else { return url }
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let temp = url.deletingPathExtension()
            .appendingPathExtension("gain")
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        try? FileManager.default.removeItem(at: temp)

        do {
            let written = try await rewrite(url: url, to: temp, factor: Float(factor(db: gainDb)))
            guard written else {
                try? FileManager.default.removeItem(at: temp)
                return url
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                try? FileManager.default.removeItem(at: temp)
                return url
            }
            // Swap only once the new file is complete and non-empty.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return url
        } catch {
            NSLog("[AudioGain] skipped: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: temp)
            return url
        }
    }

    // MARK: - Rewrite

    private static func rewrite(url: URL, to output: URL, factor: Float) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { return false }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        var sampleRate = 48_000.0
        var channels = 1
        if let description = try await audioTrack.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
            channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)

        let audioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        audioReaderOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(audioReaderOutput) else { return false }
        reader.add(audioReaderOutput)

        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 256_000 : 128_000,
        ])
        audioWriterInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioWriterInput) else { return false }
        writer.add(audioWriterInput)

        // Video is copied through untouched — no re-encode, no quality change.
        var videoPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in videoTracks {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else { return false }
            reader.add(readerOutput)

            let writerInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: try await track.load(.formatDescriptions).first
            )
            writerInput.expectsMediaDataInRealTime = false
            writerInput.transform = try await track.load(.preferredTransform)
            guard writer.canAdd(writerInput) else { return false }
            writer.add(writerInput)
            videoPairs.append((readerOutput, writerInput))
        }

        guard reader.startReading() else { return false }
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pump(input: audioWriterInput, queueLabel: "audio.gain.audio") {
                    guard let buffer = audioReaderOutput.copyNextSampleBuffer() else { return nil }
                    scale(buffer: buffer, by: factor)
                    return buffer
                }
            }
            for (readerOutput, writerInput) in videoPairs {
                group.addTask {
                    await pump(input: writerInput, queueLabel: "audio.gain.video") {
                        readerOutput.copyNextSampleBuffer()
                    }
                }
            }
        }

        guard reader.status != .failed, writer.status != .failed else {
            writer.cancelWriting()
            return false
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed
    }

    /// Feeds one writer input until its reader output runs out.
    private static func pump(input: AVAssetWriterInput,
                             queueLabel: String,
                             next: @escaping () -> CMSampleBuffer?) async {
        let queue = DispatchQueue(label: queueLabel)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = FinishBox(continuation)
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = next() else {
                        input.markAsFinished()
                        box.finish()
                        return
                    }
                    if !input.append(buffer) {
                        input.markAsFinished()
                        box.finish()
                        return
                    }
                }
            }
        }
    }

    /// Resumes its continuation exactly once, however often the writer's
    /// callback fires.
    private final class FinishBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func finish() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    /// Multiplies interleaved 32-bit float PCM in place, hard-limited to full
    /// scale so a boost can never wrap around into distortion.
    private static func scale(buffer: CMSampleBuffer, by factor: Float) {
        guard factor != 1, let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block,
                                          atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let raw = pointer else { return }
        let count = length / MemoryLayout<Float32>.size
        raw.withMemoryRebound(to: Float32.self, capacity: count) { samples in
            for index in 0..<count {
                let value = samples[index] * factor
                samples[index] = max(-1, min(1, value))
            }
        }
    }
}
