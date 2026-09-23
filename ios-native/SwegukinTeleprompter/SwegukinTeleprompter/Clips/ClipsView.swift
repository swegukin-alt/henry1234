import SwiftUI

struct ClipsView: View {
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var scripts: ScriptStore

    let scriptID: String?
    let onBack: () -> Void

    @State private var playing: RecordingItem?
    @State private var message: String?
    @State private var busy = false
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var pendingDrive: DriveRequest?
    @State private var pickingDrive = false
    @State private var copying = false
    @State private var copyDone = 0
    @State private var copyTotal = 0

    private struct DriveRequest {
        var title: String
        var items: [RecordingItem]
    }

    /// Every clip that belongs to this screen.
    private var allItems: [RecordingItem] {
        guard let scriptID else { return recordings.items }
        return recordings.items.filter { $0.scriptID == scriptID }
    }

    /// Clips currently listed: one script or every recording.
    private var items: [RecordingItem] {
        allItems.sorted { $0.createdAt < $1.createdAt }
    }

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private var headerTitle: String {
        if let scriptID {
            return scripts.script(id: scriptID)?.displayTitle ?? "Clips"
        }
        return "All videoclips"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
        Color.black.opacity(0.70).ignoresSafeArea().onTapGesture { onBack() }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(headerTitle).font(.system(size: 16, weight: .medium)).lineLimit(1)
                Text("(\(items.count))").foregroundStyle(.white.opacity(0.45))
                Spacer()
                if !items.isEmpty && !selecting {
                    Menu {
                        Button { exportFolder(items: items) } label: {
                            Label("Share clips", systemImage: "square.and.arrow.up")
                        }
                        Button { askForDrive(title: headerTitle, items: items) } label: {
                            Label("Copy to drive", systemImage: "externaldrive")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .font(.system(size: 15))
                            .frame(width: 34, height: 36)
                    }
                    .foregroundStyle(Theme.accent)
                }
                if !items.isEmpty {
                    Button(selecting ? "Done" : "Select") {
                        if selecting { endSelection() } else { selecting = true }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12)

            if items.isEmpty {
                Spacer()
                Text("No recordings yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, alignment: .center, spacing: 18) {
                    ForEach(items) { item in
                        Button {
                            if selecting { toggle(item) } else { playing = item }
                        } label: {
                            ClipGridCell(
                                item: item,
                                selected: selecting ? selected.contains(item.id) : nil
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { save(item) } label: { Label("Save to camera roll", systemImage: "square.and.arrow.down") }
                            Button { share([item]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                            Button("Delete", role: .destructive) { recordings.delete(item) }
                        }
                    }
                    }.padding(.horizontal, 16).padding(.vertical, 14)
                }

                if selecting {
                    HStack(spacing: 12) {
                        Button(selected.count == items.count ? "Deselect all" : "Select all") {
                            selected = selected.count == items.count ? [] : Set(items.map { $0.id })
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        Spacer()
                        Button { askForDrive(title: headerTitle, items: items.filter { selected.contains($0.id) }) } label: {
                            Image(systemName: "externaldrive")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 42, height: 38)
                                .background(.white.opacity(selected.isEmpty ? 0.06 : 0.16), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .disabled(selected.isEmpty)
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

        if copying {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Copying \(copyDone) of \(copyTotal)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Keep the drive connected.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(22)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .frame(maxHeight: .infinity)
        }
        }
        .sheet(isPresented: $pickingDrive) {
            DirectoryPicker(
                onPick: { url in
                    pickingDrive = false
                    startCopy(to: url)
                },
                onCancel: {
                    pickingDrive = false
                    pendingDrive = nil
                }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $playing) { item in
            ZStack(alignment: .topLeading) {
                PlayerView(url: item.url)
            }
            .swipeDownToDismiss { playing = nil }
        }
        .alert("Videoclips", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .onAppear { recordings.reconcile() }
        .swipeBack { onBack() }
        .swipeDownToDismiss { onBack() }
    }

    private func toggle(_ item: RecordingItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    private func endSelection() {
        selecting = false
        selected = []
    }

    /// AirDrop (or Files, Messages…) several clips in one send.
    private func shareSelected() {
        let urls = items.filter { selected.contains($0.id) }
            .map { $0.url }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        ShareSheetPresenter.present(urls: urls)
    }

    /// Share every clip in the folder in one go — no packaging, the share
    /// sheet simply gets all the clips, like "Select all" + Share.
    private func exportFolder(items itemsToShare: [RecordingItem]) {
        let urls = itemsToShare
            .map { $0.url }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        Haptics.tap()
        ShareSheetPresenter.present(urls: urls)
    }

    private func share(_ clips: [RecordingItem]) {
        let urls = clips.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        Haptics.tap()
        ShareSheetPresenter.present(urls: urls)
    }

    /// Step one of a drive copy: ask where on the connected drive to put it.
    private func askForDrive(title: String, items chosen: [RecordingItem]) {
        let alive = chosen.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !alive.isEmpty, !copying else { return }
        pendingDrive = DriveRequest(title: title, items: alive)
        Haptics.tap()
        pickingDrive = true
    }

    /// Step two: copy the clips. Originals are only read, never moved.
    private func startCopy(to destination: URL) {
        guard let request = pendingDrive, !copying else { return }
        pendingDrive = nil
        copying = true
        copyDone = 0
        copyTotal = request.items.count
        Task {
            do {
                let result = try await DriveExport.copy(
                    items: request.items,
                    folderName: request.title,
                    to: destination,
                    progress: { done in copyDone = done }
                )
                copying = false
                Haptics.success()
                message = "Copied \(result.copied) clip\(result.copied == 1 ? "" : "s") to “\(result.destination)” on the drive."
            } catch {
                copying = false
                Haptics.failure()
                message = error.localizedDescription
            }
        }
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

private struct ClipGridCell: View {
    @EnvironmentObject private var recordings: RecordingStore
    let item: RecordingItem
    let selected: Bool?
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(.white.opacity(0.07))
                            .overlay {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.32))
                            }
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.85), selected ? Theme.accent : Color.black.opacity(0.45))
                        .padding(6)
                }

                Text(Format.duration(item.duration))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }

            Text(item.fileName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(Format.date(item.createdAt))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .task(id: item.id) {
            thumbnail = await recordings.thumbnail(for: item)
        }
    }
}
