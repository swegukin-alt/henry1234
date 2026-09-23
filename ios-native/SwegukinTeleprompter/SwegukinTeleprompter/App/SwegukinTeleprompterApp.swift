import SwiftUI
import CoreText

@main
struct SwegukinTeleprompterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var scripts = ScriptStore()
    @StateObject private var recordings = RecordingStore()

    init() {
        // Bundle and register the same Pretendard Variable face used by the web
        // teleprompter. Registration is local to this native process.
        if let url = Bundle.main.url(forResource: "PretendardVariable", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(scripts)
                .environmentObject(recordings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    /// Apple system blue on pure black — the same minimal scheme as the web app.
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let background = Color.black
}
