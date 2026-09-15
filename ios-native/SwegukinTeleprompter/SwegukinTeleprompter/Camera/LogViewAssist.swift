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

    /// Apple Log transfer function constants, published by Apple.
    private static let R0: Float = -0.05641088
    private static let Rt: Float = 0.01
    private static let c: Float = 47.28711236
    private static let b: Float = 0.00964052
    private static let g: Float = 0.08550479
    private static let d: Float = 0.69336945

    /// Apple Log code value → scene linear.
    private static func toLinear(_ y: Float) -> Float {
        let threshold = c * (Rt - R0) * (Rt - R0)
        if y < 0 { return 0 }
        if y < threshold { return sqrt(max(0, y / c)) + R0 }
        return pow(2, (y - d) / g) - b
    }

    /// Rec. 709 opto-electronic transfer function.
    private static func rec709(_ x: Float) -> Float {
        let v = max(0, min(1, x))
        return v < 0.018 ? 4.5 * v : 1.099 * pow(v, 0.45) - 0.099
    }

    /// One 32³ cube: inverse Apple Log, BT.2020 → BT.709 primaries, 709 gamma.
    static let cube: CIFilter? = {
        let size = 32
        var data = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0
        for bi in 0..<size {
            for gi in 0..<size {
                for ri in 0..<size {
                    let lr = toLinear(Float(ri) / Float(size - 1))
                    let lg = toLinear(Float(gi) / Float(size - 1))
                    let lb = toLinear(Float(bi) / Float(size - 1))
                    // Exposure trim so 18% grey lands near a 709 middle grey.
                    let e: Float = 1.0
                    // BT.2020 → BT.709 (linear light).
                    let r = 1.660491 * lr - 0.587641 * lg - 0.072850 * lb
                    let gg = -0.124550 * lr + 1.132900 * lg - 0.008349 * lb
                    let bb = -0.018151 * lr - 0.100579 * lg + 1.118730 * lb
                    data[offset + 0] = rec709(r * e)
                    data[offset + 1] = rec709(gg * e)
                    data[offset + 2] = rec709(bb * e)
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
