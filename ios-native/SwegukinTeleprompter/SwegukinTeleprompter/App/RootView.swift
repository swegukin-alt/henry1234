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
    @State private var clipsReturnScreen: Screen = .library
    /// Kept here so going back (button or swipe) returns to the folder you were in.
    @State private var openFolderID: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch screen {
            case .library:
                libraryView
            case .editor(let id):
                if scripts.script(id: id) != nil {
                    InteractiveSwipeBack(onBack: { screen = .library }) {
                        libraryView
                    } front: {
                        editorView(id)
                    }
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
                InteractiveSwipeBack(onBack: { screen = clipsReturnScreen }) {
                    clipsBackground
                } front: {
                    ClipsView(scriptID: scriptID) {
                        screen = clipsReturnScreen
                    }
                }
            }
        }
        // Never animate the full camera/teleprompter hierarchy. That transition
        // competes with capture startup and can temporarily hide its controls.
    }

    @ViewBuilder private var clipsBackground: some View {
        if case .editor(let id) = clipsReturnScreen, scripts.script(id: id) != nil {
            editorView(id)
        } else {
            libraryView
        }
    }

    private var libraryView: some View {
        LibraryView(
            openFolderID: $openFolderID,
            onOpen: { screen = .editor($0) },
            onCreate: { screen = .editor(scripts.create().id) },
            onVideo: { screen = .prompter($0, true) },
            onClips: {
                clipsReturnScreen = .library
                screen = .clips($0)
            },
            onAllVideos: {
                clipsReturnScreen = .library
                screen = .clips(nil)
            }
        )
    }

    @ViewBuilder private func editorView(_ id: String) -> some View {
        if let script = scripts.script(id: id) {
            EditorView(
                script: script,
                onBack: { screen = .library },
                onPlay: { screen = .prompter(id, false) },
                onVideo: { screen = .prompter(id, true) },
                onClips: {
                    clipsReturnScreen = .editor(id)
                    screen = .clips(id)
                }
            )
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var scripts: ScriptStore
    @EnvironmentObject private var recordings: RecordingStore
    var onOpen: (String) -> Void
    var onCreate: () -> Void
    var onVideo: (String) -> Void
    var onClips: (String) -> Void
    var onAllVideos: () -> Void

    @Binding var openFolderID: String?
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

    private var shootingListScripts: [Script] {
        visibleScripts.filter { $0.folderID == nil }
    }

    private func scripts(in folderID: String) -> [Script] {
        visibleScripts.filter { $0.folderID == folderID }
    }

    var body: some View {
        Group {
            if let folderID = openFolderID,
               let folder = scripts.folders.first(where: { $0.id == folderID }) {
                InteractiveSwipeBack(onBack: { openFolderID = nil }) {
                    ScrollView { homeContents }
                } front: {
                    ScrollView { folderContentsBody(folder) }
                }
            } else {
                ScrollView { homeContents }
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
            HStack(spacing: 9) {
                Image("SwegukinLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Swegukin Prompter")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            HStack(alignment: .top, spacing: 14) {
                HomeActionTile(title: "Add a script", symbol: "plus", emphasized: true, action: onCreate)
                HomeActionTile(title: "New folder", symbol: "folder.badge.plus", emphasized: true) {
                    showingNewFolder = true
                }
                HomeActionTile(title: "All videoclips", symbol: "film", action: onAllVideos)
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
                            onColor: { scripts.setFolderColor(id: folder.id, color: $0) },
                            onDelete: { scripts.deleteFolder(id: folder.id) },
                            onDropScript: { scriptID in scripts.moveScript(id: scriptID, to: folder.id) }
                        )
                    }
                }
            }

            Text("Shooting list")
                .font(.title2.bold())
                .foregroundStyle(.white)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(shootingListScripts) { script in
                    ScriptClipFolderTile(
                        script: script,
                        clipCount: recordings.items.filter { $0.scriptID == script.id }.count,
                        ticked: isTicked(script),
                        onOpenClips: { onClips(script.id) },
                        onEdit: { onOpen(script.id) },
                        onToggleDone: { scripts.setDone(id: script.id, !isTicked(script)) },
                        onVideo: { onVideo(script.id) },
                        onDelete: { scripts.delete(id: script.id) }
                    )
                    .draggable(script.id)
                }
            }
            .dropDestination(for: String.self) { values, _ in
                guard let scriptID = values.first else { return false }
                scripts.moveScript(id: scriptID, to: nil)
                return true
            }

            if shootingListScripts.isEmpty {
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

    private func folderContentsBody(_ folder: ScriptFolder) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Button {
                    openFolderID = nil
                } label: {
                    Label { Text("Folders") } icon: { AppIcon("chevron.left") }
                }
                .foregroundStyle(Theme.accent)

                Spacer()

                Text("\(scripts(in: folder.id).count) scripts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(folder.name)
                .font(.title.bold())
                .foregroundStyle(.white)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(scripts(in: folder.id)) { script in
                    ScriptClipFolderTile(
                        script: script,
                        clipCount: recordings.items.filter { $0.scriptID == script.id }.count,
                        ticked: isTicked(script),
                        onOpenClips: { onClips(script.id) },
                        onEdit: { onOpen(script.id) },
                        onToggleDone: { scripts.setDone(id: script.id, !isTicked(script)) },
                        onVideo: { onVideo(script.id) },
                        onMoveShootingList: { scripts.moveScript(id: script.id, to: nil) },
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
                Text("Drag scripts onto this folder from Shooting list.")
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
                        AppIcon(symbol)
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
    let onColor: (String) -> Void
    let onDelete: () -> Void
    let onDropScript: (String) -> Void
    @State private var isTargeted = false

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 7) {
                PhosphorMap.image("folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isTargeted ? Color.green : FolderColor.color(folder.color))
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
            Menu("Folder colour") {
                ForEach(FolderColor.options, id: \.key) { option in
                    Button {
                        onColor(option.key)
                    } label: {
                        Label(option.name, systemImage: folder.color == option.key ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Button("Delete folder", role: .destructive, action: onDelete)
        }
    }
}

private struct FolderColorOption: Identifiable {
    let key: String
    let name: String
    var id: String { key }
}

private enum FolderColor {
    static let options: [FolderColorOption] = [
        FolderColorOption(key: "blue", name: "Blue"),
        FolderColorOption(key: "green", name: "Green"),
        FolderColorOption(key: "yellow", name: "Yellow"),
        FolderColorOption(key: "orange", name: "Orange"),
        FolderColorOption(key: "red", name: "Red"),
        FolderColorOption(key: "pink", name: "Pink"),
        FolderColorOption(key: "purple", name: "Purple")
    ]

    static func color(_ key: String?) -> Color {
        switch key {
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        case "pink": return .pink
        case "purple": return .purple
        default: return Theme.accent
        }
    }
}

private struct ScriptClipFolderTile: View {
    let script: Script
    let clipCount: Int
    let ticked: Bool
    let onOpenClips: () -> Void
    let onEdit: () -> Void
    let onToggleDone: () -> Void
    let onVideo: () -> Void
    var onMoveShootingList: (() -> Void)? = nil
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onOpenClips) {
                PhosphorMap.image("doc.text.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(ticked ? Theme.accent.opacity(0.48) : Theme.accent)
                    .frame(height: 72)
            }
            .buttonStyle(.plain)

            Text(script.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(ticked ? 0.55 : 1))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)

            Text("\(clipCount) clip\(clipCount == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button(action: onVideo) {
                AppIcon("video.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 68, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .contextMenu {
            Button("Edit script", action: onEdit)
            Button(ticked ? "Mark incomplete" : "Mark complete", action: onToggleDone)
            if let onMoveShootingList {
                Button("Move to Shooting list", action: onMoveShootingList)
            }
            Button("Delete", role: .destructive, action: onDelete)
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
                AppIcon("trash.fill")
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
