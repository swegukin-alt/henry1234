import Foundation
import Photos

/// Saves the existing file straight into the camera roll. The video is never
/// loaded into memory — Photos reads it from disk.
enum PhotosSaver {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Photos access is off. Turn it on in Settings to save to your camera roll."
        }
    }

    static func save(url: URL) async throws {
        guard await PermissionManager.requestPhotosAdd() else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }
}
