import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var scriptStore: ScriptStore

    @State private var draft: Script
    @State private var saveTask: Task<Void, Never>?

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
        ScrollView {
        VStack(spacing: 0) {
            HStack {
                Button(action: saveAndGoBack) { Text("‹ Scripts") }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: onVideo) {
                        Label("Video", systemImage: "video.fill")
                            .frame(height: 40).padding(.horizontal, 14)
                            .background(.white.opacity(0.07), in: Capsule())
                    }
                    Button(action: onPlay) {
                        Label("Play", systemImage: "play.fill")
                            .frame(height: 40).padding(.horizontal, 16)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .disabled(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.vertical, 8)

            TextField("Script title", text: $draft.title)
                .font(.system(size: 28, weight: .semibold))
                .textFieldStyle(.plain)
                .padding(.vertical, 8)

            TextEditor(text: $draft.body)
                .font(.system(size: 16))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 360)
                .padding(10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))

            SettingsPanel()
                .padding(.top, 32)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
        }
        .onChange(of: draft) { _, next in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await MainActor.run { scriptStore.update(next) }
            }
        }
        .onDisappear { saveTask?.cancel(); scriptStore.update(draft) }
        .onAppear { settings.lastActiveScriptID = draft.id }
    }

    private func saveAndGoBack() {
        saveTask?.cancel()
        scriptStore.update(draft)
        onBack()
    }
}
