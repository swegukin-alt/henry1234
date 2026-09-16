import Foundation
import AVFoundation
import UIKit

struct RecordingItem: Identifiable, Codable, Equatable {
    var id: String
    var fileName: String
    var createdAt: Date
    var duration: Double
    var fileSize: Int64
    var title: String
    var scriptID: String?

    var url: URL { AppPaths.recordings.appendingPathComponent(fileName) }
}

/// Real files on disk plus one small JSON index. Nothing is ever held in RAM.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var items: [RecordingItem] = []

    private let indexURL = AppPaths.applicationSupport.appendingPathComponent("recordings.json")

    init() {
        load()
        reconcile()
    }

    /// A destination for a brand new take. The file is written by AVFoundation
    /// directly — no copying afterwards.
    func newRecordingURL(id: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())
        var candidate = AppPaths.recordings.appendingPathComponent("Swegukin_\(stamp).mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = AppPaths.recordings.appendingPathComponent("Swegukin_\(stamp)-\(suffix).mov")
            suffix += 1
        }
        return candidate
    }

    func register(id: String, url: URL, title: String, scriptID: String?) {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let item = RecordingItem(
            id: id,
            fileName: url.lastPathComponent,
            createdAt: Date(),
            duration: duration.isFinite ? duration : 0,
            fileSize: size,
            title: title.isEmpty ? "Take" : title,
            scriptID: scriptID
        )
        items.removeAll { $0.id == id }
        items.insert(item, at: 0)
        sortAndPersist()
    }

    func delete(_ item: RecordingItem) {
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
        sortAndPersist()
    }

    /// Picks up anything AVFoundation finished writing while the app was gone
    /// (crash, force quit, battery) and drops index rows whose file vanished.
    func reconcile() {
        let fm = FileManager.default
        let onDisk = (try? fm.contentsOfDirectory(at: AppPaths.recordings,
                                                  includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]))
            ?? []
        let movies = onDisk.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }

        items.removeAll { !fm.fileExists(atPath: $0.url.path) }

        let known = Set(items.map { $0.fileName })
        for url in movies where !known.contains(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            let asset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(asset.duration)
            items.append(RecordingItem(
                id: url.deletingPathExtension().lastPathComponent,
                fileName: url.lastPathComponent,
                createdAt: values?.creationDate ?? Date(),
                duration: duration.isFinite ? duration : 0,
                fileSize: Int64(values?.fileSize ?? 0),
                title: "Recovered take",
                scriptID: nil
            ))
        }
        sortAndPersist()
    }

    /// Refreshes duration and size once a file has finished being written.
    func refreshMetadata(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let url = items[index].url
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if duration.isFinite { items[index].duration = duration }
        items[index].fileSize = Int64(size)
        sortAndPersist()
    }

    func thumbnail(for item: RecordingItem) async -> UIImage? {
        let asset = AVURLAsset(url: item.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.2, preferredTimescale: 600))]) { _, image, _, _, _ in
                continuation.resume(returning: image.map { UIImage(cgImage: $0) })
            }
        }
    }

    private func sortAndPersist() {
        items.sort { $0.createdAt > $1.createdAt }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([RecordingItem].self, from: data) else { return }
        items = decoded
    }
}
