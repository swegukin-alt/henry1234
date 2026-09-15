import Foundation

struct Script: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var updatedAt: Date = Date()
}

/// Scripts are tiny text records, so a single JSON file in Application Support
/// is both durable and cheap.
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [Script] = []

    private let fileURL: URL

    init() {
        fileURL = AppPaths.applicationSupport.appendingPathComponent("scripts.json")
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
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Script].self, from: data) else { return }
        scripts = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
