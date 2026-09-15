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
        ZStack(alignment: .bottom) {
        Color.black.opacity(0.70).ignoresSafeArea().onTapGesture { onBack() }
        VStack(spacing: 0) {
            HStack {
                Text("All videos").font(.system(size: 16, weight: .medium))
                Text("(\(items.count))").foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button(action: onBack) {
                    Image(systemName: "xmark").frame(width: 36, height: 36)
                }
                .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 16).padding(.top, 12)

            if items.isEmpty {
                Spacer()
                Text("No recordings yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Button { playing = item } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                                        Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    }
                                    Text("\(Format.date(item.createdAt)) · \(Format.duration(item.duration)) · \(Format.size(item.fileSize))")
                                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Menu {
                                Button { save(item) } label: { Label("Save to camera roll", systemImage: "square.and.arrow.down") }
                                Button { sharing = item } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                Button("Delete", role: .destructive) { recordings.delete(item) }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 36, height: 36).foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(10)
                        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
                    }
                    }.padding(.horizontal, 12).padding(.vertical, 8)
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
