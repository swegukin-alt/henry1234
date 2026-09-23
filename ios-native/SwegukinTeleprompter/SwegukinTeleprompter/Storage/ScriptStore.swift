import Foundation
import NaturalLanguage

struct Script: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var updatedAt: Date = Date()
    /// Manual "recorded" tick in the library. Optional so older saved scripts
    /// keep decoding unchanged.
    var done: Bool? = nil
    /// How this script is shot: "landscape" (default) or "portrait".
    /// Optional so older saved scripts keep decoding unchanged.
    var orientation: String? = nil
    /// Optional so scripts saved by older app versions remain compatible.
    var folderID: String? = nil

    /// Titles are always generated from the script itself.
    var displayTitle: String {
        let stored = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? ScriptTitle.suggest(from: body) : stored
    }
}

struct ScriptFolder: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var createdAt: Date = Date()
}

/// Builds a short topic title locally from the whole script. Natural Language
/// supplies Apple's on-device tokenization; no network or account is needed.
enum ScriptTitle {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
        "had", "has", "have", "he", "her", "his", "i", "in", "is", "it", "its",
        "my", "of", "on", "or", "our", "she", "so", "that", "the", "their", "this",
        "to", "was", "we", "were", "will", "with", "you", "your",
        "그리고", "그러나", "그런데", "나는", "내가", "우리", "이것", "저것", "하는", "하다",
        "합니다", "입니다", "있는", "없는", "위한", "대한", "에서", "으로", "에게", "하고"
    ]

    static func suggest(from body: String) -> String {
        let cleaned = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*-–—•\"'“”‘’"))
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return "New script" }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = cleaned
        var words: [(text: String, position: Int)] = []
        var frequency: [String: Int] = [:]
        var position = 0
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            let raw = String(cleaned[range]).trimmingCharacters(in: .punctuationCharacters)
            let key = raw.lowercased()
            if raw.count > 1, !stopWords.contains(key), raw.rangeOfCharacter(from: .letters) != nil {
                words.append((raw, position))
                frequency[key, default: 0] += 1
            }
            position += 1
            return true
        }

        guard !words.isEmpty else { return compact(cleaned) }
        let ranked = words.sorted {
            let left = (frequency[$0.text.lowercased()] ?? 0) * 100 - $0.position
            let right = (frequency[$1.text.lowercased()] ?? 0) * 100 - $1.position
            return left > right
        }
        let keys = Set(ranked.prefix(5).map { $0.text.lowercased() })

        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = cleaned
        var best = ""
        var bestScore = Int.min
        var sentencePosition = 0
        sentenceTokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            let sentence = String(cleaned[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = sentence.lowercased()
            let score = keys.reduce(0) { $0 + (lowered.contains($1) ? (frequency[$1] ?? 1) : 0) } * 100 - sentencePosition
            if score > bestScore { best = sentence; bestScore = score }
            sentencePosition += 1
            return true
        }
        return compact(best.isEmpty ? cleaned : best)
    }

    private static func compact(_ source: String) -> String {
        let words = source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var result = ""
        for word in words {
            let clean = word.trimmingCharacters(in: CharacterSet(charactersIn: "#*-–—•\"'“”‘’"))
            guard !clean.isEmpty else { continue }
            if !result.isEmpty, result.count + clean.count + 1 > 36 { break }
            result += result.isEmpty ? clean : " " + clean
            if result.split(separator: " ").count == 6 { break }
        }
        let title = result.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?…。！？"))
        return title.isEmpty ? "New script" : title
    }
}

/// Scripts are tiny text records, so a single JSON file in Application Support
/// is both durable and cheap.
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [Script] = []
    @Published private(set) var folders: [ScriptFolder] = []

    private let fileURL: URL
    private let backupURL: URL
    private let foldersURL: URL

    init() {
        fileURL = AppPaths.applicationSupport.appendingPathComponent("scripts.json")
        backupURL = AppPaths.applicationSupport.appendingPathComponent("scripts.backup.json")
        foldersURL = AppPaths.applicationSupport.appendingPathComponent("script-folders.json")
        load()
        loadFolders()
    }

    func script(id: String?) -> Script? {
        guard let id else { return nil }
        return scripts.first { $0.id == id }
    }

    @discardableResult
    func create() -> Script {
        let script = Script(title: "", body: "", updatedAt: Date())
        scripts.insert(script, at: 0)
        persist()
        return script
    }

    func update(_ script: Script) {
        var next = script
        next.title = ScriptTitle.suggest(from: next.body)
        next.updatedAt = Date()
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = next
        } else {
            scripts.insert(next, at: 0)
        }
        persist()
    }

    /// Ticks or unticks a script in the library without touching its text.
    func setDone(id: String, _ value: Bool) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].done = value
        persist()
    }

    @discardableResult
    func createFolder(named rawName: String) -> ScriptFolder? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let folder = ScriptFolder(name: name)
        folders.append(folder)
        persistFolders()
        return folder
    }

    func deleteFolder(id: String) {
        folders.removeAll { $0.id == id }
        for index in scripts.indices where scripts[index].folderID == id {
            scripts[index].folderID = nil
        }
        persistFolders()
        persist()
    }

    func moveScript(id: String, to folderID: String?) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        if let folderID, !folders.contains(where: { $0.id == folderID }) { return }
        scripts[index].folderID = folderID
        scripts[index].updatedAt = Date()
        persist()
    }

    func delete(id: String) {
        scripts.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        for url in [fileURL, backupURL] {
            do {
                let data = try Data(contentsOf: url)
                scripts = try JSONDecoder().decode([Script].self, from: data).map { saved in
                    var refreshed = saved
                    refreshed.title = ScriptTitle.suggest(from: saved.body)
                    return refreshed
                }
                return
            } catch {
                if FileManager.default.fileExists(atPath: url.path) {
                    print("ScriptStore load failed for \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadFolders() {
        do {
            folders = try JSONDecoder().decode([ScriptFolder].self, from: Data(contentsOf: foldersURL))
                .sorted { $0.createdAt < $1.createdAt }
        } catch {
            if FileManager.default.fileExists(atPath: foldersURL.path) {
                print("ScriptStore folder load failed: \(error.localizedDescription)")
            }
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(scripts)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("ScriptStore save failed: \(error.localizedDescription)")
        }
    }

    private func persistFolders() {
        do {
            try JSONEncoder().encode(folders).write(to: foldersURL, options: .atomic)
        } catch {
            print("ScriptStore folder save failed: \(error.localizedDescription)")
        }
    }
}
