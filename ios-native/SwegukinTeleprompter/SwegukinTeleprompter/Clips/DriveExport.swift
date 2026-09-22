import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Apple's own folder picker. On an iPhone with a USB-C drive attached the
/// drive appears here like any other location in Files, so the user can pick a
/// destination folder on the SSD. We never touch the drive directly.
struct DirectoryPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

/// Copies clips onto an external volume (or any Files location) safely.
///
/// Rules that keep footage intact:
/// * the app's own files are only ever read, never moved or deleted;
/// * each copy is written to a temporary name on the drive and only renamed
///   into place once its byte count matches the source, so an unplugged drive
///   can never leave a half file that looks complete;
/// * a failure stops the run and reports how many clips made it.
enum DriveExport {
    enum ExportError: LocalizedError {
        case noAccess
        case nothingToCopy
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAccess: return "Couldn't get permission to write to that drive."
            case .nothingToCopy: return "None of these clips are on the phone any more."
            case .failed(let detail): return detail
            }
        }
    }

    struct Result {
        var copied: Int
        var skipped: Int
        var destination: String
    }

    /// - Parameters:
    ///   - folderName: a subfolder created inside the chosen destination.
    ///   - progress: called on the main thread with the number finished so far.
    static func copy(
        items: [RecordingItem],
        folderName: String,
        to destination: URL,
        progress: @escaping (Int) -> Void
    ) async throws -> Result {
        let sources = items
        return try await Task.detached(priority: .userInitiated) {
            try perform(items: sources, folderName: folderName, to: destination, progress: progress)
        }.value
    }

    /// The actual file work, always off the main thread.
    private static func perform(
        items: [RecordingItem],
        folderName: String,
        to destination: URL,
        progress: @escaping (Int) -> Void
    ) throws -> Result {
        let report: (Int) -> Void = { done in DispatchQueue.main.async { progress(done) } }
        let fm = FileManager.default
        let sources = items.filter { fm.fileExists(atPath: $0.url.path) }
            .sorted { $0.createdAt < $1.createdAt }
        guard !sources.isEmpty else { throw ExportError.nothingToCopy }

        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }

        let folder = destination.appendingPathComponent(uniqueFolderName(safe(folderName), in: destination), isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.noAccess
        }

        let width = max(2, String(sources.count).count)
        var copied = 0
        var skipped = 0

        for (index, item) in sources.enumerated() {
            let ext = item.url.pathExtension.isEmpty ? "mov" : item.url.pathExtension
            let number = String(format: "%0\(width)d", index + 1)
            let name = "\(number)_\(safe(item.title)).\(ext)"
            let finalURL = folder.appendingPathComponent(name)
            let tempURL = folder.appendingPathComponent(".partial-\(UUID().uuidString).\(ext)")

            if fm.fileExists(atPath: finalURL.path) {
                let existing = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let source = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
                if existing == source {
                    skipped += 1
                    let done = index + 1
                    await MainActor.run { progress(done) }
                    continue
                }
                try? fm.removeItem(at: finalURL)
            }

            do {
                try fm.copyItem(at: item.url, to: tempURL)
                let written = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let expected = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
                guard written == expected else {
                    try? fm.removeItem(at: tempURL)
                    throw ExportError.failed("\(item.title) didn't copy completely. The drive may be full or was unplugged.")
                }
                try fm.moveItem(at: tempURL, to: finalURL)
                copied += 1
            } catch let error as ExportError {
                throw error
            } catch {
                try? fm.removeItem(at: tempURL)
                throw ExportError.failed("Stopped after \(copied) clip\(copied == 1 ? "" : "s"): \(error.localizedDescription)")
            }

            let done = index + 1
            await MainActor.run { progress(done) }
        }

        return Result(copied: copied, skipped: skipped, destination: folder.lastPathComponent)
    }

    private static func safe(_ raw: String) -> String {
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Clips" : trimmed
    }

    private static func uniqueFolderName(_ base: String, in parent: URL) -> String {
        let fm = FileManager.default
        var name = base
        var suffix = 2
        while fm.fileExists(atPath: parent.appendingPathComponent(name, isDirectory: true).path) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        return name
    }
}
