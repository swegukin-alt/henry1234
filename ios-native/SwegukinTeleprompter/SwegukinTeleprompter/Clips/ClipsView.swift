import SwiftUI

private struct ClipFolder: Identifiable {
    var id: String
    var title: String
    var items: [RecordingItem]
}

struct ClipsView: View {
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var scripts: ScriptStore

    let scriptID: String?
    let onBack: () -> Void

    @State private var playing: RecordingItem?
    @State private var sharing: RecordingItem?
    @State private var sharingBatch: ShareBatch?
    @State private var message: String?
    @State private var busy = false
    @State private var openFolder: String?
    @State private var selecting = false
    @State private var selected: Set<String> = []

    private static let otherKey = "__other"

    /// Every clip that belongs to this screen.
    private var allItems: [RecordingItem] {
        guard let scriptID else { return recordings.items }
        return recordings.items.filter { $0.scriptID == scriptID }
    }

    /// One folder per script, newest folder first.
    private var folders: [ClipFolder] {
        var order: [String] = []
        var grouped: [String: [RecordingItem]] = [:]
        for item in recordings.items {
            let key = item.scriptID ?? Self.otherKey
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.map { key in
            let items = grouped[key] ?? []
            let title: String
            if key == Self.otherKey {
                title = "Other recordings"
            } else {
                title = scripts.script(id: key)?.displayTitle ?? items.first?.title ?? "Script"
            }
            return ClipFolder(id: key, title: title, items: items)
        }
    }

    /// Clips currently listed: a single script, or the opened folder.
    private var items: [RecordingItem] {
        if scriptID != nil { return allItems }
        guard let openFolder else { return [] }
        return folders.first { $0.id == openFolder }?.items ?? []
    }

    private var showingFolders: Bool { scriptID == nil && openFolder == nil }

    private var headerTitle: String {
        if let openFolder, scriptID == nil {
            return folders.first { $0.id == openFolder }?.title ?? "Clips"
        }
        return "All videoclips"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
        Color.black.opacity(0.70).ignoresSafeArea().onTapGesture { onBack() }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if openFolder != nil {
                    Button {
                        openFolder = nil
                        endSelection()
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 36)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
                Text(headerTitle).font(.system(size: 16, weight: .medium)).lineLimit(1)
                Text("(\(showingFolders ? folders.count : items.count))").foregroundStyle(.white.opacity(0.45))
                Spacer()
                if !showingFolders && !items.isEmpty {
                    Button(selecting ? "Done" : "Select") {
                        if selecting { endSelection() } else { selecting = true }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                Button(action: onBack) {
                    Image(systemName: "xmark").frame(width: 36, height: 36)
                }
                .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 16).padding(.top, 12)

            if showingFolders {
                if folders.isEmpty {
                    Spacer()
                    Text("No recordings yet.").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(folders) { folder in
                                Button { openFolder = folder.id } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 15))
                                            .foregroundStyle(Theme.accent)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(folder.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text("\(folder.items.count) clip\(folder.items.count == 1 ? "" : "s")")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.white.opacity(0.5))
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.35))
                                    }
                                    .padding(10)
                                    .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
            } else if items.isEmpty {
                Spacer()
                Text("No recordings yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            if selecting {
                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 19))
                                    .foregroundStyle(selected.contains(item.id) ? Theme.accent : .white.opacity(0.3))
                            }
                            Button {
                                if selecting { toggle(item) } else { playing = item }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        if !selecting {
                                            Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                                        }
                                        Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    }
                                    Text("\(Format.date(item.createdAt)) · \(Format.duration(item.duration)) · \(Format.size(item.fileSize))")
                                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !selecting {
                                Menu {
                                    Button { save(item) } label: { Label("Save to camera roll", systemImage: "square.and.arrow.down") }
                                    Button { sharing = item } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                    Button("Delete", role: .destructive) { recordings.delete(item) }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 36, height: 36).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .padding(10)
                        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
                    }
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                }

                if selecting {
                    HStack(spacing: 12) {
                        Button(selected.count == items.count ? "Deselect all" : "Select all") {
                            selected = selected.count == items.count ? [] : Set(items.map { $0.id })
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        Spacer()
                        Button { shareSelected() } label: {
                            Label(selected.isEmpty ? "Share" : "Share \(selected.count)", systemImage: "square.and.arrow.up")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(.white.opacity(selected.isEmpty ? 0.06 : 0.16), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .disabled(selected.isEmpty)
                        Button(role: .destructive) { deleteSelected() } label: {
                            Text(selected.isEmpty ? "Delete" : "Delete \(selected.count)")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(.red.opacity(selected.isEmpty ? 0.25 : 0.85), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .disabled(selected.isEmpty)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
        }
        .frame(maxHeight: UIScreen.main.bounds.height * 0.85)
        .background(Color(red: 0.04, green: 0.04, blue: 0.045), in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        }
        .fullScreenCover(item: $playing) { item in
            ZStack(alignment: .topLeading) {
                PlayerView(url: item.url)
                Button { playing = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.title)
                }
                .padding()
            }
        }
        .sheet(item: $sharing) { item in
            ShareSheet(url: item.url)
        }
        .alert("Camera roll", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .onAppear { recordings.reconcile() }
    }

    private func toggle(_ item: RecordingItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    private func endSelection() {
        selecting = false
        selected = []
    }

    private func deleteSelected() {
        let doomed = items.filter { selected.contains($0.id) }
        guard !doomed.isEmpty else { return }
        recordings.delete(doomed)
        Haptics.success()
        endSelection()
    }

    private func save(_ item: RecordingItem) {
        busy = true
        Task {
            do {
                try await PhotosSaver.save(url: item.url)
                Haptics.success()
                message = "Saved to your camera roll."
            } catch {
                Haptics.failure()
                message = error.localizedDescription
            }
            busy = false
        }
    }
}
