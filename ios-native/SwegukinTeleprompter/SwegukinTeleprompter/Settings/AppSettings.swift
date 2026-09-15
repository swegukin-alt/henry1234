import Foundation
import Combine

/// Small user preferences only. Video never touches UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var fontSize: Double { didSet { write(fontSize, "fontSize") } }
    @Published var speed: Double { didSet { write(speed, "speed") } }          // points per second
    @Published var lineHeight: Double { didSet { write(lineHeight, "lineHeight") } }
    @Published var textWidth: Double { didSet { write(textWidth, "textWidth") } } // percent of screen
    @Published var margin: Double { didSet { write(margin, "margin") } }
    @Published var mirrorH: Bool { didSet { write(mirrorH, "mirrorH") } }
    @Published var mirrorV: Bool { didSet { write(mirrorV, "mirrorV") } }
    @Published var countdown: Int { didSet { write(countdown, "countdown") } }
    @Published var readingHighlight: Bool { didSet { write(readingHighlight, "readingHighlight") } }
    @Published var voiceFollow: Bool { didSet { write(voiceFollow, "voiceFollow") } }
    @Published var quality: String { didSet { write(quality, "quality") } }     // "720p" | "1080p" | "4k"
    @Published var frameRate: Int { didSet { write(frameRate, "frameRate") } }  // 30 | 60
    @Published var hdr: Bool { didSet { write(hdr, "hdr") } }
    @Published var stabilization: Bool { didSet { write(stabilization, "stabilization") } }
    @Published var useFrontCamera: Bool { didSet { write(useFrontCamera, "useFrontCamera") } }
    @Published var lastActiveScriptID: String? { didSet { defaults.set(lastActiveScriptID, forKey: "lastActiveScriptID") } }

    init() {
        func d(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) as? Double ?? fallback
        }
        func b(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        func i(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) as? Int ?? fallback
        }
        fontSize = d("fontSize", 72)
        speed = d("speed", 70)
        lineHeight = d("lineHeight", 1.5)
        textWidth = d("textWidth", 82)
        margin = d("margin", 24)
        mirrorH = b("mirrorH", false)
        mirrorV = b("mirrorV", false)
        countdown = i("countdown", 0)
        readingHighlight = b("readingHighlight", true)
        voiceFollow = b("voiceFollow", false)
        quality = defaults.string(forKey: "quality") ?? "1080p"
        frameRate = i("frameRate", 30)
        hdr = b("hdr", false)
        stabilization = b("stabilization", true)
        useFrontCamera = b("useFrontCamera", true)
        lastActiveScriptID = defaults.string(forKey: "lastActiveScriptID")
    }

    /// Where the reader stopped last time, per script.
    func readingPosition(for scriptID: String) -> Double {
        defaults.double(forKey: "pos.\(scriptID)")
    }

    func setReadingPosition(_ value: Double, for scriptID: String) {
        defaults.set(value, forKey: "pos.\(scriptID)")
    }

    private func write(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
