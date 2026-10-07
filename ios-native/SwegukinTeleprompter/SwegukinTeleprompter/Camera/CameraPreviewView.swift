import SwiftUI
import AVFoundation
import UIKit

/// A real AVCaptureVideoPreviewLayer hosted in SwiftUI. No web view anywhere.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    let zebraView = UIImageView()
    private let zebraPattern = UIView()
    private let zebraStripes = CAShapeLayer()
    private var stripeSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        zebraView.contentMode = .scaleAspectFill
        zebraView.clipsToBounds = true
        zebraView.isUserInteractionEnabled = false
        zebraPattern.isUserInteractionEnabled = false
        zebraPattern.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        zebraStripes.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        zebraStripes.lineWidth = 3
        zebraStripes.fillColor = nil
        zebraPattern.layer.addSublayer(zebraStripes)
        zebraPattern.mask = zebraView
        addSubview(zebraPattern)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layoutSubviews() {
        super.layoutSubviews()
        zebraPattern.frame = bounds
        zebraView.frame = bounds
        guard stripeSize != bounds.size else { return }
        stripeSize = bounds.size
        // Fine, stable 45-degree stripes in screen points, independent of the
        // camera's resolution. Only the live highlight coverage moves.
        let path = UIBezierPath()
        var x = -bounds.height
        while x <= bounds.width {
            path.move(to: CGPoint(x: x, y: bounds.height))
            path.addLine(to: CGPoint(x: x + bounds.height, y: 0))
            x += 12
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zebraStripes.frame = bounds
        zebraStripes.path = path.cgPath
        CATransaction.commit()
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var rotationAngle: CGFloat
    var mirrored: Bool
    var zebraImage: UIImage? = nil
    var onAttach: ((AVCaptureVideoPreviewLayer) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        // Fill the screen edge to edge, exactly like the web app's object-cover
        // video layer. Aspect-fit left black pillarboxes on the sides.
        view.previewLayer.videoGravity = .resizeAspectFill
        onAttach?(view.previewLayer)
        return view
    }

    static func dismantleUIView(_ uiView: PreviewUIView, coordinator: Void) {
        // CameraManager exclusively owns session shutdown on its serial queue.
        // Clearing this connection here on the main thread can race with
        // stopRunning() when leaving video mode and crash AVFoundation.
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if let cgImage = zebraImage?.cgImage {
            let angle = (Int(rotationAngle.rounded()) % 360 + 360) % 360
            let orientation: UIImage.Orientation = angle == 90 ? .right
                : (angle == 180 ? .down : (angle == 270 ? .left : .up))
            uiView.zebraView.image = UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
        } else {
            uiView.zebraView.image = nil
        }
        uiView.zebraView.transform = CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1)
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
            onAttach?(uiView.previewLayer)
        }
        guard let connection = uiView.previewLayer.connection else { return }
        // Only touch the connection when something actually changed: writing to
        // it on every frame is expensive and stutters the preview.
        if connection.videoRotationAngle != rotationAngle,
           connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != mirrored {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
}
