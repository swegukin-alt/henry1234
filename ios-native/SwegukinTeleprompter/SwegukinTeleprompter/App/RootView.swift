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
                    onVideo: { screen = .prompter($0, true) },
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
    @EnvironmentObject private var recordings: RecordingStore
    var onOpen: (String) -> Void
    var onCreate: () -> Void
    var onVideo: (String) -> Void
    var onAllVideos: () -> Void
    @State private var revealedScriptID: String?

    private func isTicked(_ script: Script) -> Bool {
        script.done ?? recordings.items.contains { $0.scriptID == script.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Swegukin Teleprompter")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)


                Button(action: onCreate) {
                    Text("Add a script")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }

                Button(action: onAllVideos) {
                    Label("All videoclips", systemImage: "film")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 0) {
                ForEach(Array(scripts.scripts.enumerated()), id: \.element.id) { index, script in
                    SwipeToDeleteRow(
                        id: script.id,
                        revealedID: $revealedScriptID,
                        onDelete: { scripts.delete(id: script.id) }
                    ) {
                        HStack(spacing: 10) {
                            Button {
                                scripts.setDone(id: script.id, !isTicked(script))
                                Haptics.tap()
                            } label: {
                                Image(systemName: isTicked(script) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(isTicked(script) ? Theme.accent : .white.opacity(0.28))
                                    .frame(width: 34, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isTicked(script) ? "Recorded" : "Not recorded")

                            Button { onOpen(script.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(script.displayTitle)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty script" : String(script.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 14)
                            }

                            Button {
                                guard !script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                onVideo(script.id)
                                Haptics.tap()
                            } label: {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.18) : Theme.accent)
                                    .frame(width: 40, height: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Record video for this script")
                        }
                        .padding(.horizontal, 12)
                        .contextMenu {
                            Button("Delete", role: .destructive) { scripts.delete(id: script.id) }
                        }
                    }
                    if index < scripts.scripts.count - 1 { Divider().overlay(.white.opacity(0.07)) }
                }
                }
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                if scripts.scripts.isEmpty {
                    Text("No scripts yet. Tap Add a script to start.")
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

/// iOS-style swipe-to-delete for a script row: swipe left to reveal a red
/// delete button, or swipe all the way to delete in one motion — the same
/// interaction as Apple's own lists. Attached with simultaneousGesture so the
/// vertical ScrollView never swallows the horizontal drag, and only one row
/// can be revealed at a time.
struct SwipeToDeleteRow<Content: View>: View {
    let id: String
    @Binding var revealedID: String?
    var onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var dragX: CGFloat = 0
    @State private var dragging = false
    @State private var abandoned = false
    @State private var startOffset: CGFloat = 0

    private let revealWidth: CGFloat = 88

    private var baseX: CGFloat { revealedID == id ? -revealWidth : 0 }
    private var currentX: CGFloat { baseX + dragX }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                Haptics.tap()
                withAnimation(.easeOut(duration: 0.2)) { revealedID = nil }
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: revealWidth, maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .background(.red)
            }
            .buttonStyle(.plain)
            .opacity(currentX < -6 ? 1 : 0)
            .disabled(currentX > -6)
            .accessibilityLabel("Delete script")

            content()
                .offset(x: currentX)
                .onTapGesture {
                    if revealedID != nil {
                        withAnimation(.easeOut(duration: 0.2)) { revealedID = nil }
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            let h = value.translation.width
                            let v = value.translation.height
                            guard !abandoned else { return }
                            if !dragging {
                                // Only engage once the drag is clearly horizontal —
                                // otherwise vertical scrolling keeps priority.
                                guard abs(h) > abs(v), abs(h) > 4 else { return }
                                if let open = revealedID, open != id {
                                    withAnimation(.easeOut(duration: 0.15)) { revealedID = nil }
                                }
                                dragging = true
                                startOffset = baseX
                            } else if abs(v) > abs(h) + 10, abs(h) < 20 {
                                // The user turned the drag into a vertical scroll —
                                // abandon the row drag and settle back.
                                abandoned = true
                                dragging = false
                                withAnimation(.easeOut(duration: 0.2)) { dragX = 0 }
                                return
                            }
                            let raw = startOffset + h
                            if raw < -revealWidth {
                                // Rubber-band resistance past the delete button.
                                let over = -revealWidth - raw
                                dragX = -revealWidth - min(over * 0.35, 70)
                            } else {
                                dragX = min(0, raw)
                            }
                        }
                        .onEnded { value in
                            defer { dragging = false; dragX = 0; startOffset = 0; abandoned = false }
                            guard !abandoned else { return }
                            let final = startOffset + value.translation.width
                            let predicted = startOffset + value.predictedEndTranslation.width
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                if final < -(revealWidth + 25) || predicted < -(revealWidth + 110) {
                                    // Full swipe: delete immediately, like Mail.
                                    revealedID = nil
                                    Haptics.tap()
                                    onDelete()
                                } else if final < -revealWidth / 2 || predicted < -revealWidth {
                                    revealedID = id
                                } else {
                                    revealedID = nil
                                }
                            }
                        }
                )
        }
    }
}
