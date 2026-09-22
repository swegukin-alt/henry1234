import Foundation
import Combine

/// Small user preferences only. Video never touches UserDefaults.
final class AppSettings: ObservableObject {
    /// These values are shared with the web reader. Keep them in one place so
    /// a fresh native install opens with exactly the same reading geometry.
    static let webFontSize = 72.0
    static let webSpeed = 70.0
    static let webLineHeight = 1.5
    static let webTextWidth = 82.0

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
    @Published var chunking: Bool { didSet { write(chunking, "chunking") } }
    @Published var pauses: Bool { didSet { write(pauses, "pauses") } }
    @Published var background: String { didSet { write(background, "background") } }
    @Published var quality: String { didSet { write(quality, "quality") } }     // "720p" | "1080p" | "4k"
    @Published var frameRate: Int { didSet { write(frameRate, "frameRate") } }  // 30 | 60
    @Published var hdr: Bool { didSet { write(hdr, "hdr") } }
    @Published var stabilization: Bool { didSet { write(stabilization, "stabilization") } }
    @Published var useFrontCamera: Bool { didSet { write(useFrontCamera, "useFrontCamera") } }
    @Published var cinematicMode: Bool { didSet { write(cinematicMode, "cinematicMode") } }
    /// Apple Log capture. Only honoured when the selected camera format
    /// actually reports .appleLog in supportedColorSpaces.
    @Published var appleLog: Bool { didSet { write(appleLog, "appleLog") } }
    /// Codec used while Apple Log is on: "prores" (large, maximum latitude) or
    /// "hevc" (much smaller files). Only applied when the movie output reports it.
    @Published var logCodec: String { didSet { write(logCodec, "logCodec") } }
    @Published var simulatedAperture: Double { didSet { write(simulatedAperture, "simulatedAperture") } }
    /// Hardware microphone gain, 0…1. Only applied when iOS reports the
    /// connected input as gain-settable.
    @Published var micGain: Double { didSet { write(micGain, "micGain") } }
    /// Manual audio trim in dB, -20 … +20, exactly like a camera's audio gain.
    /// Applied to the recorded sound, never automatic.
    @Published var micGainDb: Double { didSet { write(micGainDb, "micGainDb") } }
    
    @Published var lastActiveScriptID: String? { didSet { defaults.set(lastActiveScriptID, forKey: "lastActiveScriptID") } }

    init() {
        // Read through a local constant so the helpers never touch `self`
        // before every stored property is initialized.
        let defaults = UserDefaults.standard
        func d(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) as? Double ?? fallback
        }
        func b(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        func i(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) as? Int ?? fallback
        }
        fontSize = d("fontSize", Self.webFontSize)
        speed = d("speed", Self.webSpeed)
        // Line height is not user-adjustable on the web reader. Discard any
        // stale value written by an older native build and lock it to the web.
        lineHeight = Self.webLineHeight
        textWidth = d("textWidth", Self.webTextWidth)
        margin = d("margin", 24)
        mirrorH = b("mirrorH", false)
        mirrorV = b("mirrorV", false)
        countdown = i("countdown", 0)
        readingHighlight = b("readingHighlight", true)
        voiceFollow = b("voiceFollow", false)
        chunking = b("chunking", true)
        pauses = b("pauses", true)
        background = defaults.string(forKey: "background") ?? "black"
        quality = defaults.string(forKey: "quality") ?? "1080p"
        frameRate = i("frameRate", 30)
        hdr = b("hdr", false)
        stabilization = b("stabilization", true)
        useFrontCamera = b("useFrontCamera", true)
        cinematicMode = b("cinematicMode", false)
        appleLog = b("appleLog", false)
        simulatedAperture = d("simulatedAperture", 2.8)
        micGain = d("micGain", 0.7)
        micGainDb = max(-20, min(20, d("micGainDb", 0)))
        
        lastActiveScriptID = defaults.string(forKey: "lastActiveScriptID")
    }

    /// Where the reader stopped last time, per script.
    func readingPosition(for scriptID: String) -> Double {
        defaults.double(forKey: "pos.\(scriptID)")
    }

    func setReadingPosition(_ value: Double, for scriptID: String) {
        defaults.set(value, forKey: "pos.\(scriptID)")
    }

    func resetReaderDefaults() {
        fontSize = Self.webFontSize
        speed = Self.webSpeed
        lineHeight = Self.webLineHeight
        textWidth = Self.webTextWidth
        margin = 24
        mirrorH = false
        mirrorV = false
        countdown = 0
        readingHighlight = true
        voiceFollow = false
        chunking = true
        pauses = true
        background = "black"
    }

    private func write(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
