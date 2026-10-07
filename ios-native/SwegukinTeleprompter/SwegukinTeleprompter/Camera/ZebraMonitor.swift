import AVFoundation
import UIKit

/// Preview-only warning. Log uses an estimated ISO-dependent ceiling, not
/// measured sensor clipping. Never changes or writes camera samples.
final class ZebraMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation = 0
    private var lastFrameTime = -Double.infinity
    private var deliveryPending = false
    private var warningStart = 0.95
    private var warningFull = 1.0
    var onImage: ((UIImage?) -> Void)?

    /// User-supplied approximation: 80 IRE through ISO 400, rising toward
    /// 90 IRE above that. One-stop interpolation is an app heuristic, NOT
    /// an Apple calibration: ISO 800 → 85, ISO 1600 and above → 90 IRE.
    static func estimatedLogCeiling(iso: Double) -> Double {
        let stops = iso.isFinite && iso > 400 ? log2(iso / 400) : 0
        return 0.80 + min(2, max(0, stops)) * 0.05
    }

    func setSignalContext(appleLog: Bool, iso: Double) {
        let ceiling = appleLog ? Self.estimatedLogCeiling(iso: iso) : 1.0
        lock.lock(); defer { lock.unlock() }
        warningStart = ceiling * 0.95
        warningFull = ceiling
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        generation += 1
        lastFrameTime = -Double.infinity
        lock.unlock()
        // Called by CameraManager on the main thread.
        if !value { onImage?(nil) }
    }

    func consume(_ sample: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        lock.lock()
        // Never queue a backlog of UI updates or delay the live recording router.
        guard enabled, !deliveryPending, time.isFinite, time - lastFrameTime >= 1.0 / 30 else {
            lock.unlock(); return
        }
        lastFrameTime = time
        let token = generation
        let start = warningStart
        let full = warningFull
        deliveryPending = true
        lock.unlock()
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              let image = Self.mask(buffer, start: start, full: full) else {
            lock.lock(); deliveryPending = false; lock.unlock()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.enabled && self.generation == token
            self.deliveryPending = false
            self.lock.unlock()
            if valid { self.onImage?(UIImage(cgImage: image)) }
        }
    }

    private static func mask(_ buffer: CVPixelBuffer, start: Double, full: Double) -> CGImage? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        guard tenBit || fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) >= 1,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = min(768, sourceWidth)
        let height = max(1, sourceHeight * width / sourceWidth)
        // Video-range Y: 16…235 (8 bit), 64…940 (10 bit). x420 stores
        // its 10-bit code in the high bits of each 16-bit word.
        let black = fullRange ? 0.0 : (tenBit ? 64.0 : 16.0)
        let span = fullRange ? (tenBit ? 1023.0 : 255.0) : (tenBit ? 876.0 : 219.0)
        let threshold = Int(ceil(black + start * span))
        let ramp = max(1.0 / span, full - start)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = base.advanced(by: (y * sourceHeight / height) * stride)
            for x in 0..<width {
                let sx = x * sourceWidth / width
                let code = tenBit
                    ? Int(row.assumingMemoryBound(to: UInt16.self)[sx] >> 6)
                    : Int(row.assumingMemoryBound(to: UInt8.self)[sx])
                if code >= threshold {
                    let i = (y * width + x) * 4
                    let signal = (Double(code) - black) / span
                    let t = min(1, max(0, (signal - start) / ramp))
                    // Smoothstep: faint at the warning threshold, strongest
                    // at the estimated ceiling. No lagging frame history or
                    // ghost masks: coverage follows each fresh camera frame.
                    let alpha = UInt8((255 * t * t * (3 - 2 * t)).rounded())
                    // Coverage only. Stripes are drawn separately at display size,
                    // so rotation, crop and mask resolution cannot stretch them.
                    pixels[i] = alpha; pixels[i + 1] = alpha; pixels[i + 2] = alpha
                    pixels[i + 3] = alpha
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}