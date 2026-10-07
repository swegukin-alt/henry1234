import AVFoundation
import Foundation

/// Whole-frame reflected-light meter for Apple Log (not Sony's proprietary
/// Multi algorithm). Equal-area zones, no face/centre weighting. All reads are
/// read-only and camera samples are never modified.
final class LogExposureMeter: @unchecked Sendable {
    struct Reading {
        let offset: Double
        let time: Double
        let generation: Int
    }

    private let lock = NSLock()
    private var active = false
    private var generation = 0
    private var lastTime = -Double.infinity
    private var latest: Reading?
    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        active = enabled
        generation += 1
        lastTime = -Double.infinity
        latest = nil
    }

    func reading() -> Reading? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func consume(_ sample: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        lock.lock()
        guard active, time.isFinite, time - lastTime >= 1.0 / 30 else {
            lock.unlock(); return
        }
        lastTime = time
        let token = generation
        lock.unlock()
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              let offset = Self.offset(buffer) else { return }
        lock.lock(); defer { lock.unlock() }
        if active && generation == token {
            latest = Reading(offset: offset, time: time, generation: token)
        }
    }

    // Algebraic inverse of the original Apple Log encoding constants,
    // corroborated by colour-science (not an Apple metering API):
    // https://colour.readthedocs.io/en/latest/_modules/colour/models/rgb/transfer_functions/apple_log_profile.html
    // Decode nonlinear RGB BEFORE forming scene-linear BT.2020 luminance.
    // Inverting Y' alone would incorrectly meter strongly coloured subjects.
    private static let linearTable: [Double] = (0...4096).map { index in
        let p = Double(index) / 4096
        let transition = 47.28711236 * pow(0.01 + 0.05641088, 2)
        if p >= transition {
            return pow(2, (p - 0.69336945) / 0.08550479) - 0.00964052
        }
        return max(0, sqrt(max(0, p) / 47.28711236) - 0.05641088)
    }

    private static func linear(_ value: Double) -> Double {
        let position = min(4096, max(0, value * 4096))
        let index = Int(position)
        let next = min(4096, index + 1)
        return linearTable[index] + (linearTable[next] - linearTable[index]) * (position - Double(index))
    }

    private static func offset(_ buffer: CVPixelBuffer) -> Double? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let full = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        guard full || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let uvWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard width > 0, height > 0, uvWidth > 0, uvHeight > 0 else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        // Honour the delivered Y'CbCr matrix instead of assuming every Log
        // tap uses the same conversion. Reject unknown matrices, not fake EV.
        let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)?.takeRetainedValue()
        let matrix = attachment as? String
        let kr: Double
        let kb: Double
        if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) {
            kr = 0.2126; kb = 0.0722
        } else if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) || matrix == nil {
            // Original Apple Log specifies BT.2020; use it only as the
            // documented default when the sample carries no matrix tag.
            kr = 0.2627; kb = 0.0593
        } else { return nil }
        let kg = 1 - kr - kb
        var zones = [Double](repeating: 0, count: 48)
        // 8 × 6 zones, 8 × 8 samples each: fixed 3,072 samples irrespective
        // of resolution. Full capture frame; no faces or darkened UI involved.
        for gy in 0..<48 {
            let sy = min(height - 1, (2 * gy + 1) * height / 96)
            let yRow = yBase.advanced(by: sy * yStride).assumingMemoryBound(to: UInt16.self)
            let uvRow = uvBase.advanced(by: min(uvHeight - 1, sy * uvHeight / height) * uvStride)
                .assumingMemoryBound(to: UInt16.self)
            for gx in 0..<64 {
                let sx = min(width - 1, (2 * gx + 1) * width / 128)
                let uvX = min(uvWidth - 1, sx * uvWidth / width) * 2
                let y = (Double(yRow[sx] >> 6) - (full ? 0 : 64)) / (full ? 1023 : 876)
                let cb = (Double(uvRow[uvX] >> 6) - 512) / (full ? 1023 : 896)
                let cr = (Double(uvRow[uvX + 1] >> 6) - 512) / (full ? 1023 : 896)
                let r = linear(y + 2 * (1 - kr) * cr)
                let g = linear(y - 2 * kb * (1 - kb) / kg * cb - 2 * kr * (1 - kr) / kg * cr)
                let b = linear(y + 2 * (1 - kb) * cb)
                zones[(gy / 8) * 8 + gx / 8] += 0.2627 * r + 0.6780 * g + 0.0593 * b
            }
        }
        let mean = zones.reduce(0, +) / 3072
        // Zero is 18% scene-linear reflected grey, NOT zero compensation
        // masquerading as a measured meter value. A bright background counts.
        return log2(max(mean, 0.000001) / 0.18)
    }
}