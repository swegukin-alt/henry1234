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
        // Never animate the full camera/teleprompter hierarchy. That transition
        // competes with capture startup and can temporarily hide its controls.
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
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Never give up. Remember where you came from.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.36))

                Button(action: onCreate) {
                    Text("Let's go")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }

                Button(action: onAllVideos) {
                    Label("All videos", systemImage: "film")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 0) {
                ForEach(Array(scripts.scripts.enumerated()), id: \.element.id) { index, script in
                    Button { onOpen(script.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(script.title.isEmpty ? "Untitled" : script.title)
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty script" : String(script.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { scripts.delete(id: script.id) }
                    }
                    if index < scripts.scripts.count - 1 { Divider().overlay(.white.opacity(0.07)) }
                }
                }
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))

                if scripts.scripts.isEmpty {
                    Text("No scripts yet. Tap Let's go to start.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 96)
        }
    }
}
