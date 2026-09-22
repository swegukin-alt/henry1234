import Foundation

/// Packs every clip of one script into a single .zip so it lands on a Mac
/// as a tidy folder of numbered videos.
enum FolderExport {
    enum ExportError: LocalizedError {
        case empty
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "There are no clips in this folder yet."
            case .failed(let why): return why
            }
        }
    }

    /// Returns a zip file URL in a temporary directory. The caller shares it.
    static func makeArchive(title: String, items: [RecordingItem]) throws -> URL {
        let fm = FileManager.default
        let present = items.filter { fm.fileExists(atPath: $0.url.path) }
        guard !present.isEmpty else { throw ExportError.empty }

        let safeTitle = sanitize(title)
        let staging = fm.temporaryDirectory
            .appendingPathComponent("folder-export-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(safeTitle, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // Oldest first, numbered, so the folder reads in shooting order.
        let ordered = present.sorted { $0.createdAt < $1.createdAt }
        let width = max(2, String(ordered.count).count)
        for (index, item) in ordered.enumerated() {
            let number = String(format: "%0\(width)d", index + 1)
            let ext = item.url.pathExtension.isEmpty ? "mov" : item.url.pathExtension
            let name = "\(number)_\(sanitize(item.title)).\(ext)"
            let destination = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try fm.copyItem(at: item.url, to: destination)
        }

        // NSFileCoordinator's .forUploading option zips a directory for us.
        var coordinatorError: NSError?
        var archive: URL?
        var moveError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder,
                                       options: [.forUploading],
                                       error: &coordinatorError) { zipped in
            let destination = staging.appendingPathComponent("\(safeTitle).zip")
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: zipped, to: destination)
                archive = destination
            } catch {
                moveError = error
            }
        }
        if let coordinatorError { throw ExportError.failed(coordinatorError.localizedDescription) }
        if let moveError { throw ExportError.failed(moveError.localizedDescription) }
        guard let archive else { throw ExportError.failed("Could not package the folder.") }
        return archive
    }

    private static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty ? "Clips" : cleaned
        return String(name.prefix(60))
    }
}
