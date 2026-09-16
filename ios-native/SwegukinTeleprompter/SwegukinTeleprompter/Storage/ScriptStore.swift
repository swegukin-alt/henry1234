import Foundation

struct Script: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var updatedAt: Date = Date()

    /// What the library and the clips show when nobody typed a title.
    var displayTitle: String {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty && typed.lowercased() != "untitled" { return typed }
        return ScriptTitle.suggest(from: body)
    }
}

/// Builds a short, human title out of the first meaningful words of a script.
enum ScriptTitle {
    static func suggest(from body: String) -> String {
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let cleaned = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*-–—•\"'“”‘’"))
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return "New script" }

        var title = ""
        for word in cleaned.split(separator: " ") {
            if title.isEmpty {
                title = String(word)
            } else if title.count + word.count + 1 <= 42 {
                title += " " + word
            } else {
                title += "…"
                break
            }
        }
        if title.count > 48 { title = String(title.prefix(46)) + "…" }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) 
    }
}

/// Scripts are tiny text records, so a single JSON file in Application Support
/// is both durable and cheap.
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [Script] = []

    private let fileURL: URL
    private let backupURL: URL

    init() {
        fileURL = AppPaths.applicationSupport.appendingPathComponent("scripts.json")
        backupURL = AppPaths.applicationSupport.appendingPathComponent("scripts.backup.json")
        load()
    }

    func script(id: String?) -> Script? {
        guard let id else { return nil }
        return scripts.first { $0.id == id }
    }

    @discardableResult
    func create() -> Script {
        let script = Script(title: "Untitled", body: "", updatedAt: Date())
        scripts.insert(script, at: 0)
        persist()
        return script
    }

    func update(_ script: Script) {
        var next = script
        next.updatedAt = Date()
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = next
        } else {
            scripts.insert(next, at: 0)
        }
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
                scripts = try JSONDecoder().decode([Script].self, from: data)
                return
            } catch {
                if FileManager.default.fileExists(atPath: url.path) {
                    print("ScriptStore load failed for \(url.lastPathComponent): \(error.localizedDescription)")
                }
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
}
