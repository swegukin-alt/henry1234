import SwiftUI
import UIKit
import AVFoundation

/// Native rebuild of the web teleprompter screen. The layout, scrim, typography
/// and bottom toolbar mirror the web app exactly — only the plumbing is native.
struct PrompterView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recordings: RecordingStore

    @StateObject private var engine = TeleprompterEngine()
    @StateObject private var camera = CameraManager()
    @StateObject private var voice = VoiceFollowEngine()

    private enum Panel { case settings, size, more }

    @State private var contentHeight: CGFloat = 0
    @State private var countdownLeft = 0
    @State private var panel: Panel?
    @State private var controlsVisible = true
    @State private var showClips = false
    @State private var errorMessage: String?
    @State private var currentTakeID: String?
    @State private var saving = false
    @State private var dragStartOffset: CGFloat?
    @State private var didRestorePosition = false

    private let document: ScriptDocument

    let script: Script
    let videoMode: Bool
    let onExit: () -> Void

    init(script: Script, videoMode: Bool, onExit: @escaping () -> Void) {
        self.script = script
        self.videoMode = videoMode
        self.onExit = onExit
        self.document = ScriptDocument(script.body)
    }

    private var remaining: Int { max(0, 100 - Int((engine.progress * 100).rounded())) }
    /// Video mode must never flip the words or interface. Beam-splitter
    /// mirroring is intentionally limited to normal teleprompter mode.
    private var interfaceFlip: CGFloat { !videoMode && settings.mirrorV ? -1 : 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Camera behind everything, with the same dark scrim as the web app.
                if videoMode {
                    CameraPreviewView(
                        session: camera.session,
                        rotationAngle: camera.previewRotationAngle,
                        mirrored: camera.usingFront
                    )
                        .ignoresSafeArea()
                        .overlay {
                            // Deliberately attached to the preview so UIKit can
                            // never composite its camera layer above the scrim.
                            Rectangle()
                                .fill(Color.black.opacity(0.45))
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                        }
                } else {
                    readerBackground.ignoresSafeArea()
                }

                scriptLayer(geo: geo)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlay() }
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                if dragStartOffset == nil { dragStartOffset = engine.offset }
                                let start = dragStartOffset ?? engine.offset
                                engine.seek(to: start - value.translation.height)
                            }
                            .onEnded { _ in
                                dragStartOffset = nil
                                settings.setReadingPosition(Double(engine.offset), for: script.id)
                            }
                    )

                if countdownLeft > 0 {
                    Text("\(countdownLeft)")
                        .font(.system(size: 120, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                overlayChips(geo: geo)

                if controlsVisible {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        progressLine
                        bottomToolbar
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack {
                        Button {
                            controlsVisible = true
                        } label: {
                            Text("•••")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(.black.opacity(0.4), in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(.top, 10)
                }

                if let panel { popover(for: panel) }

                RemoteKeyCatcher(onAction: handle(action:))
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
            .onAppear {
                engine.viewportHeight = geo.size.height
                engine.speed = settings.speed
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
        .sheet(isPresented: $showClips) {
            ClipsView(scriptID: script.id)
                .environmentObject(recordings)
        }
        .alert("Camera", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Open Settings") { PermissionManager.openSettings() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Script

    private func scriptLayer(geo: GeometryProxy) -> some View {
        // LOCKED READING TYPOGRAPHY — matches the web app: weight 500,
        // line-height 1.5, -0.015em tracking, words never split.
        ScriptText(
            document: document,
            fontSize: settings.fontSize,
            lineHeight: settings.lineHeight,
            highlightIndex: highlightIndex,
            foreground: videoMode || settings.background == "black" ? .white : .black
        )
        .tracking(-0.015 * settings.fontSize)
        .frame(width: geo.size.width * settings.textWidth / 100, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
            // Web uses a 20vh lead-in and 80vh tail. Together they add one
            // viewport, allowing every final word to pass the reading line.
            engine.contentHeight = height + geo.size.height
            if !didRestorePosition, height > 0 {
                didRestorePosition = true
                engine.seek(to: settings.readingPosition(for: script.id))
            }
        }
        // Web spacer: 20vh of clear space above the first line.
        .offset(y: geo.size.height * 0.20 - engine.offset)
        .scaleEffect(x: (!videoMode && settings.mirrorH) ? -1 : 1,
                     y: interfaceFlip)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Chips (top row, same positions as the web app)

    private func overlayChips(geo: GeometryProxy) -> some View {
        VStack {
            ZStack(alignment: .top) {
                HStack(alignment: .top) {
                    if videoMode {
                        if camera.isRecording {
                            HStack(spacing: 8) {
                                Circle().fill(.white).frame(width: 10, height: 10)
                                Text("REC \(Format.duration(camera.elapsed))")
                                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.red.opacity(0.9), in: Capsule())
                        } else {
                            Button { showClips = true } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "film").foregroundStyle(Theme.accent)
                                    Text("Clips").font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.black.opacity(0.6), in: Capsule())
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    Text("\(remaining)% left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                }

                if videoMode && camera.isReady && controlsVisible {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill").font(.system(size: 12))
                        Text(camera.micName.isEmpty ? "Built-in mic" : camera.micName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(maxWidth: geo.size.width * 0.60)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .scaleEffect(y: interfaceFlip)

            Spacer()
        }
    }

    // MARK: - Toolbar

    private var progressLine: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Color.white.opacity(0.1)
                Theme.accent.frame(width: proxy.size.width * engine.progress)
            }
        }
        .frame(height: 2)
    }

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            iconButton("chevron.left", tint: Color(red: 0.22, green: 0.74, blue: 0.97), size: 24) { exit() }
            Spacer(minLength: 0)
            if !videoMode {
                iconButton("arrow.up.arrow.down", tint: settings.mirrorV ? Theme.accent : .white.opacity(0.75), size: 24) {
                    settings.mirrorV.toggle()
                }
                Spacer(minLength: 0)
            }
            iconButton(engine.isPlaying ? "pause.fill" : "play.fill", tint: Color(red: 0.22, green: 0.74, blue: 0.97), size: 28) { togglePlay() }
            Spacer(minLength: 0)
            if videoMode {
                Button {
                    camera.isRecording ? stopRecording() : startRecording()
                } label: {
                    Image(systemName: camera.isRecording ? "stop.fill" : "circle.fill")
                        .font(.system(size: camera.isRecording ? 20 : 24))
                        .foregroundStyle(.white)
                        .frame(width: toolbarButtonSize, height: toolbarButtonSize)
                        .background(camera.isRecording ? Color.red : Color.red.opacity(0.9), in: Circle())
                }
                .disabled((!camera.isReady && !camera.isRecording) || saving)
                .opacity((!camera.isReady && !camera.isRecording) || saving ? 0.4 : 1)
                Spacer(minLength: 0)
            }
            iconButton("slider.horizontal.3", size: 24) { toggle(.settings) }
            Spacer(minLength: 0)
            iconButton("textformat", size: 24) { toggle(.size) }
            Spacer(minLength: 0)
            Button { toggle(.more) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: toolbarButtonSize, height: toolbarButtonSize)
                    .background(Theme.accent.opacity(0.9), in: Circle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .padding(.bottom, safeBottom)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.85))
        .scaleEffect(y: interfaceFlip)
    }

    private var safeBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
    }

    /// The web toolbar uses 40px on compact phones and 44px when space permits.
    private var toolbarButtonSize: CGFloat {
        UIScreen.main.bounds.width >= 430 ? 44 : 40
    }

    private func iconButton(_ name: String, tint: Color = .white.opacity(0.75), size: CGFloat = 20, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: toolbarButtonSize, height: toolbarButtonSize)
        }
    }

    private func toggle(_ p: Panel) { panel = (panel == p) ? nil : p }

    // MARK: - Popovers

    @ViewBuilder
    private func popover(for p: Panel) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { panel = nil }

            VStack(alignment: .leading, spacing: 12) {
                switch p {
                case .settings:
                    popRow("Speed", "\(Int(settings.speed))") {
                        Slider(value: $settings.speed, in: 10...250, step: 1)
                            .onChange(of: settings.speed) { _, v in engine.speed = v }
                    }
                    popRow("Width", "\(Int(settings.textWidth))%") {
                        Slider(value: $settings.textWidth, in: 50...100, step: 1)
                    }
                    HStack(spacing: 8) {
                        backgroundButton("Dark", value: "black")
                        backgroundButton("Light", value: "white")
                        backgroundButton("Sepia", value: "sepia")
                    }
                case .size:
                    popRow("Font size", "\(Int(settings.fontSize))px") {
                        Slider(value: $settings.fontSize, in: 24...140, step: 1)
                    }
                case .more:
                    Button { engine.reset(); panel = nil } label: {
                        Text("↺ Reset").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OutlineButtonStyle(active: false))

                    if !videoMode {
                        Button { settings.mirrorV.toggle() } label: {
                            Text("Flip ↕ (beam-splitter rig)").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OutlineButtonStyle(active: settings.mirrorV))
                    }

                    if videoMode && !camera.modes.isEmpty {
                        Text("Resolution").font(.caption).foregroundStyle(.white.opacity(0.7))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(camera.modes) { mode in
                                let active = settings.quality == mode.quality
                                    && settings.frameRate == mode.fps && settings.hdr == mode.hdr
                                Button {
                                    settings.quality = mode.quality
                                    settings.frameRate = mode.fps
                                    settings.hdr = mode.hdr
                                } label: {
                                    Text(mode.label).font(.system(size: 12, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(OutlineButtonStyle(active: active))
                                .disabled(camera.isRecording)
                            }
                        }
                    }

                    Text("Reading assist").font(.caption).foregroundStyle(.white.opacity(0.7))
                    assistRow("Reading highlight", isOn: $settings.readingHighlight)
                    assistRow("Chunk phrases", isOn: $settings.chunking)
                    assistRow("Slow at punctuation", isOn: $settings.pauses)
                    assistRow("Voice-follow highlight", isOn: $settings.voiceFollow)

                    Text("Tap the script to play / pause. Bluetooth remotes (Desview, AirTurn) work too.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(14)
            .frame(maxWidth: 420)
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.1)))
            .padding(.horizontal, 16)
            .padding(.bottom, 78 + safeBottom)
            .scaleEffect(y: interfaceFlip)
        }
    }

    private func popRow<Content: View>(_ label: String, _ value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(value).font(.caption.monospaced()).foregroundStyle(Theme.accent)
            }
            content()
        }
    }

    private func assistRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack {
                Text(label).font(.system(size: 14))
                Spacer()
                Text(isOn.wrappedValue ? "On" : "Off").font(.system(size: 11)).opacity(0.7)
            }
        }
        .buttonStyle(OutlineButtonStyle(active: isOn.wrappedValue))
    }

    private func backgroundButton(_ label: String, value: String) -> some View {
        Button { settings.background = value } label: {
            Text(label).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(OutlineButtonStyle(active: settings.background == value))
    }

    // MARK: - Behaviour

    private var highlightIndex: Int? {
        if settings.voiceFollow, let matched = voice.matchedIndex { return matched }
        guard settings.readingHighlight else { return nil }
        let words = document.words.count
        guard words > 0 else { return nil }
        return min(words - 1, Int(engine.progress * Double(words)))
    }

    private var readerBackground: Color {
        switch settings.background {
        case "white": return .white
        case "sepia": return Color(red: 0.96, green: 0.91, blue: 0.80)
        default: return .black
        }
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
        guard !camera.isRecording else { return }
        finish()
        onExit()
    }

    private func togglePlay() {
        Haptics.tap()
        if panel != nil { panel = nil; return }
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
        controlsVisible = !engine.isPlaying
        if engine.isPlaying { panel = nil }
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
        case .nudgeUp: engine.nudge(points: -max(60, engine.viewportHeight * 0.18))
        case .nudgeDown: engine.nudge(points: max(60, engine.viewportHeight * 0.18))
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

/// Bordered pill button used by the prompter popovers, matching the web look.
struct OutlineButtonStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(active ? Theme.accent : Color.white.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(active ? Theme.accent : Color.white.opacity(0.15))
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
