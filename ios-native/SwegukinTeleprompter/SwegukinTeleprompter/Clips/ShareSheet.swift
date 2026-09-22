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
