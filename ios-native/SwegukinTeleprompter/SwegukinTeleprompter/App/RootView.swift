import SwiftUI

enum Screen: Equatable {
    case library
    case editor(String)
    case prompter(String, Bool)   // script id, video mode
    case clips(String?)           // nil = all videos
}

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var scripts: ScriptStore
    @EnvironmentObject private var recordings: RecordingStore

    @State private var screen: Screen = .library

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch screen {
            case .library:
                LibraryView(
                    onOpen: { screen = .editor($0) },
                    onCreate: { screen = .editor(scripts.create().id) },
                    onAllVideos: { screen = .clips(nil) }
                )
            case .editor(let id):
                if let script = scripts.script(id: id) {
                    EditorView(
                        script: script,
                        onBack: { screen = .library },
                        onPlay: { screen = .prompter(id, false) },
                        onVideo: { screen = .prompter(id, true) },
                        onClips: { screen = .clips(id) }
                    )
                } else {
                    Color.clear.onAppear { screen = .library }
                }
            case .prompter(let id, let video):
                if let script = scripts.script(id: id) {
                    PrompterView(script: script, videoMode: video) {
                        screen = .editor(id)
                    }
                    .ignoresSafeArea()
                } else {
                    Color.clear.onAppear { screen = .library }
                }
            case .clips(let scriptID):
                ClipsView(scriptID: scriptID) {
                    screen = scriptID.map { Screen.editor($0) } ?? .library
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: screen)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var scripts: ScriptStore
    var onOpen: (String) -> Void
    var onCreate: () -> Void
    var onAllVideos: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Let's kick some ass")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Text("Never give up. Remember where you came from.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button(action: onCreate) {
                    Text("Let's go")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.black)
                }

                Button(action: onAllVideos) {
                    Label("All videos", systemImage: "film")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                }

                ForEach(scripts.scripts) { script in
                    Button { onOpen(script.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(script.title.isEmpty ? "Untitled" : script.title)
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(script.body.isEmpty ? "Empty script" : String(script.body.prefix(80)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { scripts.delete(id: script.id) }
                    }
                }

                if scripts.scripts.isEmpty {
                    Text("No scripts yet. Tap Let's go to start.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                }
            }
            .padding(18)
        }
    }
}
