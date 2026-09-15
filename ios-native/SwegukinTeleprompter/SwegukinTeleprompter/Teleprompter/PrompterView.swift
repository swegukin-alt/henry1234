import SwiftUI
import UIKit
import AVFoundation

struct PrompterView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recordings: RecordingStore

    @StateObject private var engine = TeleprompterEngine()
    @StateObject private var camera = CameraManager()
    @StateObject private var voice = VoiceFollowEngine()

    @State private var contentHeight: CGFloat = 0
    @State private var countdownLeft = 0
    @State private var showSettings = false
    @State private var errorMessage: String?
    @State private var currentTakeID: String?
    @State private var saving = false

    let script: Script
    let videoMode: Bool
    let onExit: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if videoMode {
                    CameraPreviewView(session: camera.session, rotationAngle: camera.previewRotationAngle)
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

                scriptLayer(geo: geo)

                // Tap anywhere to play / pause, exactly like the web app.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlay() }
                    .onTapGesture(count: 2) { camera.focus(at: CGPoint(x: 0.5, y: 0.5)) }

                if countdownLeft > 0 {
                    Text("\(countdownLeft)")
                        .font(.system(size: 120, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.accent)
                }

                VStack {
                    topBar
                    Spacer()
                    toolbar
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                RemoteKeyCatcher(onAction: handle(action:))
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
            .onAppear {
                engine.viewportHeight = geo.size.height
                engine.speed = settings.speed
                engine.seek(to: settings.readingPosition(for: script.id))
            }
            .onChange(of: geo.size) { _, size in
                engine.viewportHeight = size.height
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await begin() }
        .onDisappear { finish() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            camera.refreshRotation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if camera.isRecording { stopRecording() } else { engine.pause() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsPanel(modes: camera.modes)
                .presentationDetents([.medium, .large])
        }
        .alert("Camera", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Open Settings") { PermissionManager.openSettings() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Layers

    private func scriptLayer(geo: GeometryProxy) -> some View {
        ScriptText(
            body_: script.body,
            fontSize: settings.fontSize,
            lineHeight: settings.lineHeight,
            highlightIndex: highlightIndex
        )
        .padding(.horizontal, settings.margin)
        .frame(width: geo.size.width * settings.textWidth / 100, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
            engine.contentHeight = height
        }
        .offset(y: geo.size.height * 0.22 - engine.offset)
        // In video mode the script stays readable: only the camera image is
        // mirrored by the capture connection, never the words.
        .scaleEffect(x: (!videoMode && settings.mirrorH) ? -1 : 1,
                     y: settings.mirrorV ? -1 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { exit() } label: { Image(systemName: "chevron.left") }
            Spacer()
            if camera.isRecording {
                Label(Format.duration(camera.elapsed), systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .font(.footnote.monospacedDigit().bold())
            }
            Text("\(Int(engine.progress * 100))%")
                .font(.footnote.monospacedDigit().bold())
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            if !camera.status.isEmpty {
                Text(camera.status).font(.caption2).foregroundStyle(.orange)
            }
            if videoMode && !camera.micName.isEmpty {
                Text(camera.micName).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button { engine.toggle() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { settings.speed = max(10, settings.speed - 5); engine.speed = settings.speed } label: {
                    Image(systemName: "tortoise.fill")
                }
                Text("\(Int(settings.speed))")
                    .font(.caption.monospacedDigit())
                Button { settings.speed = min(250, settings.speed + 5); engine.speed = settings.speed } label: {
                    Image(systemName: "hare.fill")
                }
                Button { settings.mirrorH.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }

                if videoMode {
                    Button { camera.toggleTorch() } label: {
                        Image(systemName: camera.torchOn ? "bolt.fill" : "bolt.slash")
                    }
                    Button {
                        camera.isRecording ? stopRecording() : startRecording()
                    } label: {
                        Image(systemName: camera.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 34))
                            .foregroundStyle(.red)
                    }
                    .disabled(!camera.isReady || saving)
                }
            }
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.black.opacity(0.45), in: Capsule())
        }
    }

    // MARK: - Behaviour

    private var highlightIndex: Int? {
        if settings.voiceFollow, let matched = voice.matchedIndex { return matched }
        guard settings.readingHighlight else { return nil }
        let words = ScriptText.wordRanges(in: script.body).count
        guard words > 0 else { return nil }
        return min(words - 1, Int(engine.progress * Double(words)))
    }

    private func begin() async {
        IdleTimer.keepAwake(true)
        if videoMode {
            do {
                try await camera.start(
                    front: settings.useFrontCamera,
                    quality: settings.quality,
                    fps: settings.frameRate,
                    hdr: settings.hdr,
                    stabilization: settings.stabilization
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if settings.voiceFollow && !videoMode {
            await voice.start(script: script.body)
        }
    }

    private func finish() {
        engine.pause()
        voice.stop()
        if camera.isRecording { stopRecording() }
        camera.stop()
        IdleTimer.keepAwake(false)
        settings.setReadingPosition(Double(engine.offset), for: script.id)
    }

    private func exit() {
        // While recording the remote and the back button must never drop a take.
        guard !camera.isRecording else { return }
        finish()
        onExit()
    }

    private func togglePlay() {
        Haptics.tap()
        if settings.countdown > 0 && !engine.isPlaying && countdownLeft == 0 {
            countdownLeft = settings.countdown
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                Task { @MainActor in
                    countdownLeft -= 1
                    if countdownLeft <= 0 {
                        timer.invalidate()
                        engine.speed = settings.speed
                        engine.play()
                    }
                }
            }
            return
        }
        engine.speed = settings.speed
        engine.toggle()
    }

    private func startRecording() {
        let id = UUID().uuidString
        let url = recordings.newRecordingURL(id: id)
        do {
            try camera.startRecording(to: url)
            currentTakeID = id
            engine.speed = settings.speed
            engine.play()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() {
        guard camera.isRecording else { return }
        saving = true
        engine.pause()
        let id = currentTakeID ?? UUID().uuidString
        camera.stopRecording { result in
            Task { @MainActor in
                saving = false
                switch result {
                case .success(let url):
                    recordings.register(id: id, url: url, title: script.title, scriptID: script.id)
                    recordings.refreshMetadata(id: id)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
                currentTakeID = nil
            }
        }
    }

    private func handle(action: RemoteAction) {
        switch action {
        case .togglePlay: togglePlay()
        case .speedUp: settings.speed = min(250, settings.speed + 5); engine.speed = settings.speed
        case .speedDown: settings.speed = max(10, settings.speed - 5); engine.speed = settings.speed
        case .nudgeUp: engine.nudge(points: -settings.fontSize)
        case .nudgeDown: engine.nudge(points: settings.fontSize)
        case .fontUp: settings.fontSize = min(140, settings.fontSize + 2)
        case .fontDown: settings.fontSize = max(24, settings.fontSize - 2)
        case .reset: engine.reset()
        case .exit: exit()
        case .toggleRecord:
            guard videoMode else { return }
            camera.isRecording ? stopRecording() : startRecording()
        }
    }
}
