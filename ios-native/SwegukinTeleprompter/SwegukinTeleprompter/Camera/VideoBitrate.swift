import AVFoundation
import Foundation
import VideoToolbox

/// Makes the HEVC bitrate chosen on the compression slider true in the file.
///
/// The movie file output treats the requested bitrate as a hint and the
/// iPhone often records far above it. After each take the file's measured
/// video bitrate is checked; if it overshoots the target, the video is
/// re-encoded once with AVAssetWriter at exactly the chosen average bitrate
/// (10-bit HEVC so Apple Log's tonal range is kept). Audio is copied untouched.
///
/// The original is only replaced after a complete new file exists whose
/// measured bitrate is lower, so a take can never be lost by this step.
enum VideoBitrate {
    /// Allowed overshoot before a re-encode is triggered.
    private static let tolerance = 1.10

    static func enforce(targetMbps: Int, on url: URL) async {
        guard targetMbps > 0, FileManager.default.fileExists(atPath: url.path) else { return }
        let target = Double(targetMbps) * 1_000_000
        guard let measured = await measuredVideoBitrate(url) else { return }
        NSLog("[Bitrate] \(url.lastPathComponent) measured=\(String(format: "%.1f", measured / 1_000_000)) Mbps target=\(targetMbps) Mbps")
        guard measured > target * tolerance else { return }

        let temp = url.deletingPathExtension()
            .appendingPathExtension("bitrate")
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        try? FileManager.default.removeItem(at: temp)

        do {
            guard try await reencode(url: url, to: temp, bitrate: Int(target)),
                  let newRate = await measuredVideoBitrate(temp),
                  newRate > 0, newRate < measured else {
                try? FileManager.default.removeItem(at: temp)
                NSLog("[Bitrate] re-encode skipped, original kept")
                return
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            NSLog("[Bitrate] \(url.lastPathComponent) now \(String(format: "%.1f", newRate / 1_000_000)) Mbps")
            CameraManager.logRecordedFileDiagnostics(url)
        } catch {
            NSLog("[Bitrate] failed: \(error.localizedDescription) — original kept")
            try? FileManager.default.removeItem(at: temp)
        }
    }

    static func measuredVideoBitrate(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.estimatedDataRate) else { return nil }
        return Double(rate)
    }

    private static func reencode(url: URL, to output: URL, bitrate: Int) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return false }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let size = try await videoTrack.load(.naturalSize)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let transform = try await videoTrack.load(.preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.metadata = (try? await asset.load(.metadata)) ?? []

        // Decode to 10-bit so Log / HDR gradations survive the re-encode.
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { return false }
        reader.add(videoOut)

        let frameRate = fps > 0 ? Int(fps.rounded()) : 30
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate
            ]
        ])
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform
        guard writer.canAdd(videoIn) else { return false }
        writer.add(videoIn)

        // Audio copied through untouched.
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in audioTracks {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(out) else { return false }
            reader.add(out)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: try await track.load(.formatDescriptions).first)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            audioPairs.append((out, input))
        }

        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(videoIn, label: "bitrate.video") { videoOut.copyNextSampleBuffer() } }
            for (out, input) in audioPairs {
                group.addTask { await pump(input, label: "bitrate.audio") { out.copyNextSampleBuffer() } }
            }
        }

        guard reader.status == .completed, writer.status != .failed else {
            writer.cancelWriting()
            return false
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        return writer.status == .completed
    }

    private static func pump(_ input: AVAssetWriterInput, label: String,
                             next: @escaping () -> CMSampleBuffer?) async {
        let queue = DispatchQueue(label: label)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let box = Once(c)
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = next(), input.append(buffer) else {
                        input.markAsFinished()
                        box.finish()
                        return
                    }
                }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private var c: CheckedContinuation<Void, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<Void, Never>) { self.c = c }
        func finish() {
            lock.lock(); let p = c; c = nil; lock.unlock()
            p?.resume()
        }
    }
}
