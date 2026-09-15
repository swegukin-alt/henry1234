import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var scriptStore: ScriptStore

    @State private var draft: Script
    @State private var showSettings = false

    let onBack: () -> Void
    let onPlay: () -> Void
    let onVideo: () -> Void
    let onClips: () -> Void

    init(script: Script, onBack: @escaping () -> Void, onPlay: @escaping () -> Void,
         onVideo: @escaping () -> Void, onClips: @escaping () -> Void) {
        _draft = State(initialValue: script)
        self.onBack = onBack
        self.onPlay = onPlay
        self.onVideo = onVideo
        self.onClips = onClips
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: onBack) { Label("Scripts", systemImage: "chevron.left") }
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                Button(action: onClips) { Image(systemName: "film") }
            }
            .font(.subheadline.bold())
            .foregroundStyle(Theme.accent)

            TextField("Title", text: $draft.title)
                .font(.title3.bold())
                .textFieldStyle(.plain)
                .padding(12)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))

            TextEditor(text: $draft.body)
                .font(.system(size: 17))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 10) {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.black)
                }
                Button(action: onVideo) {
                    Label("Video", systemImage: "video.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .onChange(of: draft) { _, next in scriptStore.update(next) }
        .onAppear { settings.lastActiveScriptID = draft.id }
        .sheet(isPresented: $showSettings) {
            SettingsPanel().presentationDetents([.medium, .large])
        }
    }
}
