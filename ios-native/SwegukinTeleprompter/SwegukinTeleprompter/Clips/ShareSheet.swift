import SwiftUI
import UIKit

/// The real iOS share sheet: AirDrop, Messages, Files, everything.
/// Takes one or many files, so several clips can go over AirDrop in one send.
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    init(url: URL) { self.urls = [url] }
    init(urls: [URL]) { self.urls = urls }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Wrapper so a list of files can drive a SwiftUI `.sheet(item:)`.
struct ShareBatch: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Presents from the currently visible controller, including when Clips is
/// already inside another sheet. This keeps per-script sharing reliable.
@MainActor
enum ShareSheetPresenter {
    static func present(urls: [URL]) {
        guard !urls.isEmpty,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \ .isKeyWindow)?.rootViewController else { return }

        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }

        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 1, width: 1, height: 1)
        }
        presenter.present(controller, animated: true)
    }
}
