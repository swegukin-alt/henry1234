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
    static let accent = Color(red: 0.98, green: 0.75, blue: 0.22)
    static let background = Color(red: 0.039, green: 0.039, blue: 0.039)
}
