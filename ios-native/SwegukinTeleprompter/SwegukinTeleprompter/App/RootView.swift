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
    @State private var openFolderID: String?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    private func isTicked(_ script: Script) -> Bool {
        script.done ?? recordings.items.contains { $0.scriptID == script.id }
    }

    private var visibleScripts: [Script] {
        scripts.scripts
            .filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var recentScripts: [Script] {
        visibleScripts.filter { $0.folderID == nil }
    }

    private func scripts(in folderID: String) -> [Script] {
        visibleScripts.filter { $0.folderID == folderID }
    }

    var body: some View {
        ScrollView {
            if let folderID = openFolderID,
               let folder = scripts.folders.first(where: { $0.id == folderID }) {
                folderContents(folder)
            } else {
                homeContents
            }
        }
        .alert("New folder", isPresented: $showingNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                _ = scripts.createFolder(named: newFolderName)
                newFolderName = ""
                Haptics.tap()
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Name the folder for these scripts.")
        }
    }

    private var homeContents: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image("SwegukinLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityLabel("Swegukin")

            HStack(alignment: .top, spacing: 14) {
                HomeActionTile(title: "Add a script", symbol: "plus", emphasized: true, action: onCreate)
                HomeActionTile(title: "All videoclips", symbol: "film", action: onAllVideos)
                HomeActionTile(title: "New folder", symbol: "folder.badge.plus") {
                    showingNewFolder = true
                }
            }

            if !scripts.folders.isEmpty {
                Text("Folders")
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(scripts.folders) { folder in
                        ScriptFolderTile(
                            folder: folder,
                            count: scripts(in: folder.id).count,
                            onOpen: { openFolderID = folder.id },
                            onDelete: { scripts.deleteFolder(id: folder.id) },
                            onDropScript: { scriptID in scripts.moveScript(id: scriptID, to: folder.id) }
                        )
                    }
                }
            }

            Text("Recent")
                .font(.title2.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                ForEach(Array(recentScripts.enumerated()), id: \.element.id) { index, script in
                    recentRow(script)
                    if index < recentScripts.count - 1 {
                        Divider().overlay(.white.opacity(0.07))
                    }
                }
            }
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .dropDestination(for: String.self) { values, _ in
                guard let scriptID = values.first else { return false }
                scripts.moveScript(id: scriptID, to: nil)
                return true
            }

            if recentScripts.isEmpty {
                Text(visibleScripts.isEmpty ? "No scripts yet. Tap Add a script to start." : "All scripts are organized in folders.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 96)
    }

    private func folderContents(_ folder: ScriptFolder) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Button {
                    openFolderID = nil
                } label: {
                    Label("Folders", systemImage: "chevron.left")
                }
                .foregroundStyle(Theme.accent)

                Spacer()

                Text("\(scripts(in: folder.id).count) scripts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 50, weight: .regular))
                    .foregroundStyle(Theme.accent)
                Text(folder.name)
                    .font(.title.bold())
                    .foregroundStyle(.white)
            }

            if scripts.folders.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ScriptDropTarget(title: "Recent", symbol: "clock") { scriptID in
                            scripts.moveScript(id: scriptID, to: nil)
                        }
                        ForEach(scripts.folders.filter { $0.id != folder.id }) { destination in
                            ScriptDropTarget(title: destination.name, symbol: "folder.fill") { scriptID in
                                scripts.moveScript(id: scriptID, to: destination.id)
                            }
                        }
                    }
                }
            } else {
                ScriptDropTarget(title: "Recent", symbol: "clock") { scriptID in
                    scripts.moveScript(id: scriptID, to: nil)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(scripts(in: folder.id)) { script in
                    FolderScriptTile(
                        script: script,
                        ticked: isTicked(script),
                        onOpen: { onOpen(script.id) },
                        onToggleDone: { scripts.setDone(id: script.id, !isTicked(script)) },
                        onVideo: { onVideo(script.id) },
                        onMoveRecent: { scripts.moveScript(id: script.id, to: nil) },
                        onDelete: { scripts.delete(id: script.id) }
                    )
                    .draggable(script.id)
                }
            }
            .dropDestination(for: String.self) { values, _ in
                guard let scriptID = values.first else { return false }
                scripts.moveScript(id: scriptID, to: folder.id)
                return true
            }

            if scripts(in: folder.id).isEmpty {
                Text("Drag scripts onto this folder from Recent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 96)
    }

    private func recentRow(_ script: Script) -> some View {
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
                        .foregroundStyle(isTicked(script) ? .white.opacity(0.58) : .white.opacity(0.28))
                        .frame(width: 34, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isTicked(script) ? "Recorded" : "Not recorded")

                Button { onOpen(script.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(script.displayTitle)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(String(script.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                }

                Button {
                    onVideo(script.id)
                    Haptics.tap()
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record video for this script")
            }
            .padding(.horizontal, 12)
            .background(isTicked(script) ? Color.white.opacity(0.035) : Color.clear)
            .opacity(isTicked(script) ? 0.56 : 1)
            .contextMenu {
                Button("Delete", role: .destructive) { scripts.delete(id: script.id) }
            }
        }
        .draggable(script.id)
    }
}

private struct HomeActionTile: View {
    let title: String
    let symbol: String
    var emphasized = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(emphasized ? Theme.accent : Color.white.opacity(0.08))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct ScriptFolderTile: View {
    let folder: ScriptFolder
    let count: Int
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onDropScript: (String) -> Void
    @State private var isTargeted = false

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isTargeted ? Color.green : Theme.accent)
                    .frame(height: 72)
                    .scaleEffect(isTargeted ? 1.06 : 1)
                Text(folder.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("\(count) \(count == 1 ? "script" : "scripts")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .top)
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { values, _ in
            guard let scriptID = values.first else { return false }
            onDropScript(scriptID)
            Haptics.tap()
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.16)) { isTargeted = targeted }
        }
        .contextMenu {
            Button("Delete folder", role: .destructive, action: onDelete)
        }
    }
}

private struct FolderScriptTile: View {
    let script: Script
    let ticked: Bool
    let onOpen: () -> Void
    let onToggleDone: () -> Void
    let onVideo: () -> Void
    let onMoveRecent: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onOpen) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(ticked ? 0.035 : 0.08))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(ticked ? .white.opacity(0.38) : Theme.accent)
                    }
            }
            .buttonStyle(.plain)

            Text(script.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(ticked ? 0.55 : 1))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)

            HStack(spacing: 12) {
                Button(action: onToggleDone) {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                }
                Button(action: onVideo) {
                    Image(systemName: "video.fill")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(ticked ? .white.opacity(0.45) : Theme.accent)
            .font(.system(size: 16))
        }
        .contextMenu {
            Button("Move to Recent", action: onMoveRecent)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct ScriptDropTarget: View {
    let title: String
    let symbol: String
    let onDropScript: (String) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
            Text(title)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(isTargeted ? Color.green : Theme.accent)
        .frame(width: 82, height: 64)
        .background(.white.opacity(isTargeted ? 0.13 : 0.06), in: RoundedRectangle(cornerRadius: 12))
        .scaleEffect(isTargeted ? 1.04 : 1)
        .dropDestination(for: String.self) { values, _ in
            guard let scriptID = values.first else { return false }
            onDropScript(scriptID)
            Haptics.tap()
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.16)) { isTargeted = targeted }
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
