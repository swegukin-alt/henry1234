import AVFoundation
import Combine
import Foundation
import SwiftUI

/// True dBFS metering taken from the live capture audio, measured sample by
/// sample from `AVCaptureAudioDataOutput`. Nothing here touches the movie file
/// output, so recording behaviour is unchanged; the monitor simply stops
/// publishing while a take is running.
final class AudioLevelMonitor: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Loudest sample in the most recent buffer, in dBFS (-80 … 0).
    @Published private(set) var peakDb: Double = -80
    /// Short-term average level, in dBFS (-80 … 0).
    @Published private(set) var averageDb: Double = -80
    /// Highest peak since the last reset, in dBFS.
    @Published private(set) var peakHoldDb: Double = -80
    /// True when a sample reached full scale in the last few seconds.
    @Published private(set) var isClipping = false
    @Published private(set) var isActive = false

    /// Suspended for the whole time a take is being written.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused {
                DispatchQueue.main.async { [weak self] in
                    self?.isActive = false
                    self?.peakDb = -80
                    self?.averageDb = -80
                }
            } else {
                reset()
            }
        }
    }

    /// Manual trim in dB. The meter shows the level as it will be written to
    /// the file, so the white -12 mark stays meaningful at any gain setting.
    var gainDb: Double = 0

    private var smoothedAverage = -80.0
    private var lastClipAt: Date?
    private var lastPublish = Date.distantPast
    private var lastPeakHoldAt = Date.distantPast

    func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.peakHoldDb = -80
            self?.isClipping = false
        }
        smoothedAverage = -80
        lastClipAt = nil
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !isPaused else { return }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        var peak: Double = 0
        var sumSquares: Double = 0
        var count = 0

        for buffer in UnsafeMutableAudioBufferListPointer(&list) {
            guard let data = buffer.mData else { continue }
            let bytes = Int(buffer.mDataByteSize)
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0

            if isFloat {
                let samples = data.bindMemory(to: Float32.self, capacity: bytes / MemoryLayout<Float32>.size)
                let n = bytes / MemoryLayout<Float32>.size
                for index in 0..<n {
                    let value = Double(abs(samples[index]))
                    peak = max(peak, value)
                    sumSquares += value * value
                }
                count += n
            } else if asbd.mBitsPerChannel == 16 {
                let samples = data.bindMemory(to: Int16.self, capacity: bytes / MemoryLayout<Int16>.size)
                let n = bytes / MemoryLayout<Int16>.size
                for index in 0..<n {
                    let value = Double(abs(Int(samples[index]))) / 32768.0
                    peak = max(peak, value)
                    sumSquares += value * value
                }
                count += n
            } else if asbd.mBitsPerChannel == 32 {
                let samples = data.bindMemory(to: Int32.self, capacity: bytes / MemoryLayout<Int32>.size)
                let n = bytes / MemoryLayout<Int32>.size
                for index in 0..<n {
                    let value = Double(abs(Int64(samples[index]))) / 2_147_483_648.0
                    peak = max(peak, value)
                    sumSquares += value * value
                }
                count += n
            }
        }

        guard count > 0 else { return }
        let trim = AudioGain.factor(db: gainDb)
        let rms = (sumSquares / Double(count)).squareRoot() * trim
        let trimmedPeak = peak * trim
        let peakValue = Self.decibels(trimmedPeak)
        let rmsValue = Self.decibels(rms)
        let clipped = trimmedPeak >= 0.999
        if clipped { lastClipAt = Date() }

        // A meter ballistics pass: fast attack, slow release, so the bar reads
        // like a broadcast meter instead of flickering.
        if rmsValue > smoothedAverage {
            smoothedAverage = rmsValue
        } else {
            smoothedAverage += (rmsValue - smoothedAverage) * 0.25
        }
        let average = smoothedAverage

        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= 1.0 / 30.0 else { return }
        lastPublish = now
        let holdExpired = now.timeIntervalSince(lastPeakHoldAt) > 1.5
        let clipStillFresh = lastClipAt.map { now.timeIntervalSince($0) < 2 } ?? false

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPaused else { return }
            self.isActive = true
            self.peakDb = peakValue
            self.averageDb = average
            if peakValue >= self.peakHoldDb || holdExpired {
                self.peakHoldDb = peakValue
                self.lastPeakHoldAt = now
            }
            self.isClipping = clipStillFresh
        }
    }

    private static func decibels(_ amplitude: Double) -> Double {
        guard amplitude > 0.0000001 else { return -80 }
        return max(-80, min(0, 20 * log10(amplitude)))
    }
}

/// Compact FX6-style audio meter: two segmented bars with a -12 dBFS target
/// mark and a red over-level warning. Shown only before recording.
struct AudioLevelMeter: View {
    @ObservedObject var monitor: AudioLevelMonitor
    var micName: String

    private let floorDb: Double = -60

    private func fraction(_ db: Double) -> Double {
        min(1, max(0, (db - floorDb) / (0 - floorDb)))
    }

    private var color: Color {
        if monitor.isClipping || monitor.peakDb > -3 { return .red }
        if monitor.peakDb > -9 { return .yellow }
        return .green
    }

    var body: some View {
        if monitor.isActive {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text(micName.isEmpty ? "MIC" : micName.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(String(format: "%.0f dB", max(-60, monitor.peakDb)))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color)
                        .monospacedDigit()
                }

                bar(level: fraction(monitor.averageDb), peak: fraction(monitor.peakHoldDb))
                bar(level: fraction(monitor.peakDb), peak: fraction(monitor.peakHoldDb))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Microphone level")
            .accessibilityValue(String(format: "%.0f decibels full scale", monitor.peakDb))
            .allowsHitTesting(false)
        }
    }

    private func bar(level: Double, peak: Double) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.14))
                Rectangle()
                    .fill(color)
                    .frame(width: width * level)
                // -12 dBFS target mark: peaks sitting here never run hot.
                Rectangle()
                    .fill(.white.opacity(0.8))
                    .frame(width: 1)
                    .offset(x: width * fraction(-12))
                Rectangle()
                    .fill(.white)
                    .frame(width: 1.5)
                    .offset(x: max(0, width * peak - 1.5))
            }
        }
        .frame(width: 96, height: 5)
        .clipShape(RoundedRectangle(cornerRadius: 1))
        .animation(.linear(duration: 0.05), value: level)
    }
}
