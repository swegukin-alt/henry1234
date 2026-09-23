import SwiftUI

/// App-wide icon set: Phosphor Icons (MIT, phosphoricons.com), bundled as
/// vector template images in Assets.xcassets/Icons. Call sites keep their
/// familiar SF Symbol names; each maps to its Phosphor replacement.
/// An invisible SF Symbol supplies the size, so `.font(...)` still sizes
/// icons exactly as before and tint/foregroundStyle still colours them.
enum PhosphorMap {
    static let names: [String: String] = [
        "video.fill": "ph-video-camera-fill",
        "trash.fill": "ph-trash-fill",
        "square.and.arrow.up": "ph-export-fill",
        "square.and.arrow.up.on.square": "ph-share-fat-fill",
        "mic.fill": "ph-microphone-fill",
        "folder.fill": "ph-folder-simple-fill",
        "film": "ph-film-strip-fill",
        "externaldrive": "ph-hard-drives-fill",
        "exclamationmark.triangle.fill": "ph-warning-fill",
        "doc.text.fill": "ph-file-text-fill",
        "square.and.arrow.down": "ph-download-simple-fill",
        "play.fill": "ph-play-fill",
        "pause.fill": "ph-pause-fill",
        "checkmark.circle.fill": "ph-check-circle-fill",
        "circle.fill": "ph-circle-fill",
        "circle": "ph-circle-bold",
        "textformat": "ph-text-aa-fill",
        "slider.horizontal.3": "ph-sliders-horizontal-fill",
        "folder.badge.plus": "ph-folder-plus-fill",
        "chevron.left": "ph-caret-left-bold",
        "checkmark": "ph-check-bold",
        "ellipsis": "ph-dots-three-bold",
        "arrow.up.arrow.down": "ph-arrows-down-up-bold",
        "plus": "ph-plus-bold",
    ]

    /// Full-size image for places that use `.resizable()`.
    static func image(_ sfName: String) -> Image {
        if let asset = names[sfName] { return Image(asset).renderingMode(.template) }
        return Image(systemName: sfName)
    }
}

struct AppIcon: View {
    let sfName: String
    init(_ sfName: String) { self.sfName = sfName }

    var body: some View {
        if let asset = PhosphorMap.names[sfName] {
            Image(systemName: sfName)
                .hidden()
                .overlay(
                    Image(asset)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                )
        } else {
            Image(systemName: sfName)
        }
    }
}
