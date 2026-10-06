import AVFoundation
import UIKit

/// Preview-only 95% signal warning. Never changes or writes camera samples.
final class ZebraMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation = 0
    private var lastFrameTime = -Double.infinity
    var onImage: ((UIImage?) -> Void)?

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
        guard enabled, time.isFinite, time - lastFrameTime >= 1.0 / 12 else {
            lock.unlock(); return
        }
        lastFrameTime = time
        let token = generation
        lock.unlock()
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              let image = Self.mask(buffer) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.enabled && self.generation == token
            self.lock.unlock()
            if valid { self.onImage?(UIImage(cgImage: image)) }
        }
    }

    private static func mask(_ buffer: CVPixelBuffer) -> CGImage? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard tenBit || fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) >= 1,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = min(384, sourceWidth)
        let height = max(1, sourceHeight * width / sourceWidth)
        // Video-range Y: 16…235 (8 bit), 64…940 (10 bit). x420 stores
        // its 10-bit code in the high bits of each 16-bit word.
        let threshold = tenBit ? 897 : (fullRange ? 243 : 225)
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
                    let shade: UInt8 = (x + y) % 12 < 6 ? 255 : 0
                    pixels[i] = shade; pixels[i + 1] = shade; pixels[i + 2] = shade
                    pixels[i + 3] = 255
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}