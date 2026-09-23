import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var scriptStore: ScriptStore

    @State private var draft: Script
    @State private var saveTask: Task<Void, Never>?
    @State private var editorHeight: CGFloat = 360

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
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button(action: saveAndGoBack) {
                            Text("‹ Scripts")
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button(action: saveAndStay) {
                                Label("Save", systemImage: "checkmark")
                                    .frame(height: 40)
                                    .padding(.horizontal, 14)
                                    .background(.white.opacity(0.07), in: Capsule())
                            }

                            Button(action: { saveAndOpen(onVideo) }) {
                                Label("Video", systemImage: "video.fill")
                                    .frame(height: 40)
                                    .padding(.horizontal, 14)
                                    .background(.white.opacity(0.07), in: Capsule())
                            }

                            Button(action: { saveAndOpen(onPlay) }) {
                                Label("Play", systemImage: "play.fill")
                                    .frame(height: 40)
                                    .padding(.horizontal, 16)
                                    .background(Theme.accent, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                        .opacity(isDraftEmpty ? 0.35 : 1)
                        .disabled(isDraftEmpty)
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 8)

                    TextEditor(text: $draft.body)
                        .font(.system(size: 16))
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        // Match the web editor's 40vh box. The editor scrolls its own
                        // contents instead of growing to the full height of a pasted
                        // script and pushing settings thousands of points down-screen.
                        .frame(height: editorHeight)
                        .padding(10)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("SHOOTING ORIENTATION")
                            .font(.system(size: 13))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.36))
                        Picker("Shooting orientation", selection: Binding(
                            get: { ScriptOrientation.from(draft.orientation) },
                            set: { draft.orientation = $0.rawValue }
                        )) {
                            ForEach(ScriptOrientation.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("The screen turns this way on its own when you shoot this script.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.top, 24)

                    SettingsPanel()
                        .padding(.top, 32)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .onAppear {
                // Capture the viewport once. Keyboard animations must not resize
                // the script box while someone is typing or pasting a long script.
                editorHeight = max(260, geometry.size.height * 0.40)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: draft) { _, next in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    scriptStore.update(next)
                }
            }
        }
        .onDisappear {
            saveTask?.cancel()
            persistOrDelete()
        }
        .onAppear {
            settings.lastActiveScriptID = draft.id
        }
    }

    private var isDraftEmpty: Bool {
        draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Saves the script to the library and stays in the editor, for people
    /// who want to park the text now and shoot the video later.
    private func saveAndStay() {
        saveTask?.cancel()
        scriptStore.update(draft)
        Haptics.tap()
    }

    private func saveAndGoBack() {
        saveTask?.cancel()
        persistOrDelete()
        onBack()
    }

    private func saveAndOpen(_ action: () -> Void) {
        saveTask?.cancel()
        scriptStore.update(draft)
        action()
    }

    private func persistOrDelete() {
        if isDraftEmpty {
            scriptStore.delete(id: draft.id)
        } else {
            scriptStore.update(draft)
        }
    }
}
