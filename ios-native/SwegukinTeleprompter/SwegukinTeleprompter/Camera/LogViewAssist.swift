import AVFoundation
import CoreImage
import MetalKit
import SwiftUI
import UIKit

/// Monitoring-only Apple Log → Rec. 709 view assist.
///
/// Nothing here touches the recording path: `AVCaptureMovieFileOutput` keeps
/// writing the camera's pure Apple Log signal. This renders a separate live
/// preview through a generated Rec. 709 cube so the flat log image can be
/// judged on screen, exactly like a monitor LUT that is never burnt in.
enum LogToRec709 {

    // MARK: Apple Log transfer function (Apple Log Profile White Paper)
    //
    //   P(R) = 0                        , R <  R0
    //        = c * (R - R0)^2           , R0 <= R < Rt
    //        = g * log2(R + b) + d      , R >= Rt
    //
    // where R is scene linear reflectance (1.0 == 100% diffuse white) and
    // P is the stored Apple Log code value in [0, 1].
    private static let R0: Float = -0.05641088
    private static let Rt: Float = 0.01
    private static let c: Float = 47.28711236
    private static let b: Float = 0.00964052
    private static let g: Float = 0.08550479
    private static let d: Float = 0.69336945

    /// Apple Log code value → scene linear reflectance (exact inverse of P).
    private static func toLinear(_ p: Float) -> Float {
        if p <= 0 { return R0 }
        let knee = c * (Rt - R0) * (Rt - R0)      // ≈ 0.2086, the code value at Rt
        if p < knee { return sqrtf(p / c) + R0 }
        return powf(2, (p - d) / g) - b
    }

    /// Highlight shoulder. Apple Log holds far more than 100% white (code 1.0
    /// is ≈ 12.0 in linear), so a straight clip would blow every highlight.
    /// Below the knee the response is untouched — 18% grey stays exactly where
    /// Rec. 709 puts it — above it, values roll off smoothly towards 1.0.
    private static func shoulder(_ x: Float) -> Float {
        let knee: Float = 0.6
        if x <= knee { return max(0, x) }
        let range = 1 - knee
        return knee + range * (1 - expf(-(x - knee) / range))
    }

    /// Rec. 709 opto-electronic transfer function (ITU-R BT.709-6).
    private static func rec709(_ x: Float) -> Float {
        let v = max(0, min(1, x))
        return v < 0.018 ? 4.5 * v : 1.099 * powf(v, 0.45) - 0.099
    }

    /// One 64³ cube: inverse Apple Log → linear, BT.2020 → BT.709 primaries,
    /// highlight shoulder, Rec. 709 gamma.
    static let cube: CIFilter? = {
        let size = 64
        var data = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0
        let last = Float(size - 1)
        for bi in 0..<size {
            for gi in 0..<size {
                for ri in 0..<size {
                    let lr = toLinear(Float(ri) / last)
                    let lg = toLinear(Float(gi) / last)
                    let lb = toLinear(Float(bi) / last)
                    // BT.2020 → BT.709 (linear light).
                    let r = 1.660491 * lr - 0.587641 * lg - 0.072850 * lb
                    let gg = -0.124550 * lr + 1.132900 * lg - 0.008349 * lb
                    let bb = -0.018151 * lr - 0.100579 * lg + 1.118730 * lb
                    data[offset + 0] = rec709(shoulder(r))
                    data[offset + 1] = rec709(shoulder(gg))
                    data[offset + 2] = rec709(shoulder(bb))
                    data[offset + 3] = 1
                    offset += 4
                }
            }
        }
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(size, forKey: "inputCubeDimension")
        filter?.setValue(Data(bytes: data, count: data.count * MemoryLayout<Float>.size),
                         forKey: "inputCubeData")
        return filter
    }()

    static func apply(to image: CIImage) -> CIImage {
        guard let cube else { return image }
        cube.setValue(image, forKey: kCIInputImageKey)
        return cube.outputImage ?? image
    }
}

/// Receives frames from the capture session and hands the latest one to the
/// on-screen renderer. Holding only the newest frame keeps memory flat.
final class LogAssistFrameSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    var onFrame: (() -> Void)?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = buffer
        lock.unlock()
        onFrame?()
    }

    func takeLatest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

/// Metal view that draws the tone-mapped monitoring image.
final class LogAssistMTKView: MTKView, MTKViewDelegate {
    var source: LogAssistFrameSource?
    var mirrored = false

    private var ciContext: CIContext?
    private var commandQueue: MTLCommandQueue?

    init(source: LogAssistFrameSource) {
        let mtlDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: mtlDevice)
        self.source = source
        self.framebufferOnly = false
        self.isOpaque = true
        self.backgroundColor = .black
        self.enableSetNeedsDisplay = false
        self.isPaused = false
        self.preferredFramesPerSecond = 30
        if let mtlDevice {
            ciContext = CIContext(mtlDevice: mtlDevice)
            commandQueue = mtlDevice.makeCommandQueue()
        }
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unused") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let ciContext, let commandQueue,
              let buffer = source?.takeLatest(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var image = CIImage(cvPixelBuffer: buffer)
        image = LogToRec709.apply(to: image)
        if mirrored {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -image.extent.width, y: 0))
        }

        // Fill the drawable edge to edge, matching the camera preview's
        // resizeAspectFill behaviour.
        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        guard target.width > 0, target.height > 0, image.extent.width > 0 else { return }
        let scale = max(target.width / image.extent.width, target.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (target.width - scaled.extent.width) / 2 - scaled.extent.origin.x
        let dy = (target.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        let placed = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))

        ciContext.render(placed,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: CGRect(origin: .zero, size: target),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct LogAssistPreview: UIViewRepresentable {
    let source: LogAssistFrameSource
    var mirrored: Bool

    func makeUIView(context: Context) -> LogAssistMTKView {
        let view = LogAssistMTKView(source: source)
        view.mirrored = mirrored
        return view
    }

    func updateUIView(_ uiView: LogAssistMTKView, context: Context) {
        uiView.mirrored = mirrored
    }
}
