import SwiftUI

@main
struct SwegukinTeleprompterApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var scripts = ScriptStore()
    @StateObject private var recordings = RecordingStore()

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
