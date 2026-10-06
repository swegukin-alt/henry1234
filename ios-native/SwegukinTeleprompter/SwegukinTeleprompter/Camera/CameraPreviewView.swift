import SwiftUI
import AVFoundation
import UIKit

/// A real AVCaptureVideoPreviewLayer hosted in SwiftUI. No web view anywhere.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    let zebraView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        zebraView.contentMode = .scaleAspectFill
        zebraView.clipsToBounds = true
        zebraView.isUserInteractionEnabled = false
        addSubview(zebraView)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layoutSubviews() {
        super.layoutSubviews()
        zebraView.frame = bounds
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
