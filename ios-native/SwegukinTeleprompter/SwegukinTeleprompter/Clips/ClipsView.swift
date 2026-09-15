import SwiftUI

struct ClipsView: View {
    @EnvironmentObject private var recordings: RecordingStore

    let scriptID: String?
    let onBack: () -> Void

    @State private var playing: RecordingItem?
    @State private var sharing: RecordingItem?
    @State private var message: String?
    @State private var busy = false

    private var items: [RecordingItem] {
        guard let scriptID else { return recordings.items }
        return recordings.items.filter { $0.scriptID == scriptID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                Spacer()
                Text(scriptID == nil ? "All videos" : "Takes").font(.headline)
                Spacer()
                Button { recordings.reconcile() } label: { Image(systemName: "arrow.clockwise") }
            }
            .font(.subheadline.bold())
            .foregroundStyle(Theme.accent)
            .padding(16)

            if items.isEmpty {
                Spacer()
                Text("No recordings yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { playing = item } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.headline).foregroundStyle(.white)
                                    Text("\(Format.date(item.createdAt)) · \(Format.duration(item.duration)) · \(Format.size(item.fileSize))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 10) {
                                Button {
                                    save(item)
                                } label: {
                                    Label("Save to camera roll", systemImage: "square.and.arrow.down")
                                        .font(.caption.bold())
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy)

                                Button { sharing = item } label: {
                                    Label("Share", systemImage: "square.and.arrow.up").font(.caption.bold())
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Color.white.opacity(0.04))
                        .swipeActions {
                            Button("Delete", role: .destructive) { recordings.delete(item) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
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
