import SwiftUI
import AVFoundation
import UIKit

/// A real AVCaptureVideoPreviewLayer hosted in SwiftUI. No web view anywhere.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var rotationAngle: CGFloat
    var mirrored: Bool
    var onAttach: ((AVCaptureVideoPreviewLayer) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        onAttach?(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
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
