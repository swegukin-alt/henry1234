import SwiftUI
import UIKit
import AVFoundation

/// Native rebuild of the web teleprompter screen. The layout, scrim, typography
/// and bottom toolbar mirror the web app exactly — only the plumbing is native.
///
/// Performance note: the scrolling engine is held in plain `@State` (not
/// `@StateObject`) so its 120 Hz offset updates only re-render the small views
/// that actually observe it — the script layer, the progress line and the
/// percentage badge. The camera preview, chips and toolbar stay untouched.
struct PrompterView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recordings: RecordingStore

    @State private var engine = TeleprompterEngine()
    @StateObject private var camera = CameraManager()
    @StateObject private var horizon = HorizonLevelMonitor()

    private enum Panel { case settings, size, more }

    @State private var contentHeight: CGFloat = 0
    @State private var panel: Panel?
    @State private var showClips = false
    @State private var errorMessage: String?
    @State private var currentTakeID: String?
    @State private var saving = false
    @State private var controlsVisible = true
    @State private var didRestorePosition = false
    @State private var didFinish = false

    @State private var document: ScriptDocument

    let script: Script
    let videoMode: Bool
    let onExit: () -> Void

    init(script: Script, videoMode: Bool, onExit: @escaping () -> Void) {
        self.script = script
        self.videoMode = videoMode
        self.onExit = onExit
        let chunking = UserDefaults.standard.object(forKey: "chunking") as? Bool ?? true
        let document = ScriptDocument(script.body, chunking: chunking)
        _document = State(initialValue: document)
    }

    /// Video mode must never flip the words or interface. Beam-splitter
    /// mirroring is intentionally limited to normal teleprompter mode.
    private var interfaceFlip: CGFloat { !videoMode && settings.mirrorV ? -1 : 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if videoMode {
                    CameraPreviewView(
                        session: camera.session,
                        rotationAngle: camera.previewRotationAngle,
                        mirrored: camera.usingFront,
                        onAttach: { camera.attach(previewLayer: $0) }
                    )
                    .ignoresSafeArea()
                    .overlay {
                        // Attached to the preview so UIKit can never composite
                        // its camera layer above the scrim.
                        Rectangle()
                            .fill(Color.black.opacity(0.45))
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }

                } else {
                    readerBackground.ignoresSafeArea()
                }

                ScriptScrollLayer(
                    engine: engine,
                    document: document,
                    fontSize: settings.fontSize,
                    lineHeight: settings.lineHeight,
                    textWidth: settings.textWidth,
                    viewportWidth: geo.size.width,
                    viewportHeight: geo.size.height,
                    foreground: .white,
                    mirrorH: !videoMode && settings.mirrorH,
                    flip: interfaceFlip,
                    onContentHeight: { height in
                        contentHeight = height
                        // Web uses a 20vh lead-in and an 80vh tail. Together they
                        // add one viewport so every last word passes the eye line.
                        engine.contentHeight = height + geo.size.height
                        if !didRestorePosition, height > 0 {
                            didRestorePosition = true
                            engine.seek(to: settings.readingPosition(for: script.id))
                        }
                    }
                )

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if videoMode && camera.recordingRequested {
                            Haptics.tap()
                            panel = nil
                            controlsVisible.toggle()
                        } else {
                            togglePlay()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                engine.drag(translation: value.translation.height)
                            }
                            .onEnded { value in
                                // UIKit-style momentum: the script keeps gliding
                                // after release, while auto-scroll resumes at the
                                // selected reading speed.
                                let projectedDistance = value.predictedEndTranslation.height - value.translation.height
                                engine.endDrag(velocity: projectedDistance / 0.25)
                                settings.setReadingPosition(Double(engine.offset), for: script.id)
                            }
                    )

                overlayChips(geo: geo)
                    .zIndex(20)

                if videoMode && !camera.recordingRequested {
                    VStack(alignment: .trailing, spacing: 6) {
                        AudioLevelMeter(monitor: camera.levelMonitor, micName: camera.micName)
                        HorizonLevelGauge(monitor: horizon)
                    }
                    .padding(.trailing, 14 + safeHorizontal.trailing)
                    .padding(.bottom, 74 + safeBottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .zIndex(25)
                }

                if controlsVisible {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ProgressLine(engine: engine)
                        bottomToolbar
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .zIndex(30)
                } else if !camera.recordingRequested {
                    Button {
                        Haptics.tap()
                        controlsVisible = true
                        pause()
                    } label: {
                        Text("•••")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                    .padding(.top, 10)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .zIndex(30)
                }

                if let panel { popover(for: panel).zIndex(40) }

                RemoteKeyCatcher(onAction: handle(action:))
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
            // Second guard: the screen stack itself never grows past the
            // device screen, so controls stay anchored for any script length.
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear {

                engine.viewportHeight = geo.size.height
                engine.contentHeight = contentHeight + geo.size.height
                engine.speed = settings.speed
                if videoMode && !camera.recordingRequested { horizon.start() }
            }
            .onChange(of: geo.size) { _, size in
                engine.viewportHeight = size.height
                engine.contentHeight = contentHeight + size.height
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await begin() }
        .onAppear {
            // Video mode turns the phone the way this script is shot —
            // landscape unless the script says portrait.
            if videoMode {
                OrientationLock.shared.lock(to: ScriptOrientation.from(script.orientation).mask)
            }
        }
        .onDisappear {
            if videoMode { OrientationLock.shared.release() }
            horizon.stop()
            camera.setMeteringPaused(true)
            finish()
        }
        .onChange(of: settings.speed) { _, value in engine.speed = value }
        .onChange(of: camera.recordingRequested) { _, recording in
            camera.setMeteringPaused(recording)
            if recording {
                horizon.stop()
            } else if videoMode {
                horizon.start()
            }
        }
        .onChange(of: settings.micGainDb) { _, value in
            camera.levelMonitor.gainDb = value
            if camera.micGainSupported { camera.setMicGain(AudioGain.hardwareValue(db: value)) }
        }
        .onChange(of: camera.micGainSupported) { _, supported in
            if supported { camera.setMicGain(AudioGain.hardwareValue(db: settings.micGainDb)) }
        }
        
        .onChange(of: settings.stabilization) { _, on in camera.setStabilization(on) }
        .onChange(of: settings.shutterAngle) { _, on in camera.setShutterAngle(on) }
        .onChange(of: settings.chunking) { _, enabled in
            document = ScriptDocument(script.body, chunking: enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            camera.refreshRotation()
            // The scene orientation settles just after the device notification.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                camera.refreshRotation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // Pulling down Notification Center / Control Center, a banner or an
            // alarm must never end a take. Only the record button stops it.
            if !camera.recordingRequested { pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // Never translate a system overlay or app-state transition into a
            // recording stop. If iOS closes capture itself, CameraManager's
            // delegate preserves the file that was already written to disk.
            if !camera.recordingRequested { pause() }
        }
        .sheet(isPresented: $showClips) {
            ClipsView(scriptID: script.id, onBack: { showClips = false })
                .environmentObject(recordings)
        }
        .alert("Camera", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Open Settings") { PermissionManager.openSettings() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Chips (top row, same positions as the web app)

    private func overlayChips(geo: GeometryProxy) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                HStack(alignment: .top) {
                    if videoMode {
                        if camera.recordingRequested {
                            HStack(spacing: 8) {
                                Circle().fill(.white).frame(width: 10, height: 10)
                                Text(
                                    camera.shutterAngleOn && !camera.shutterSpeedLabel.isEmpty
                                        ? "REC \(Format.duration(camera.elapsed)) · \(camera.shutterSpeedLabel)"
                                        : "REC \(Format.duration(camera.elapsed))"
                                )
                                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.red.opacity(0.9), in: Capsule())
                        } else {
                            Button { showClips = true } label: {
                                HStack(spacing: 6) {
                                    AppIcon("film").foregroundStyle(Theme.accent)
                                    Text("Clips").font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.black.opacity(0.6), in: Capsule())
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    RemainingBadge(engine: engine)
                }

                if videoMode && camera.isReady && controlsVisible {
                    HStack(spacing: 6) {
                        AppIcon("mic.fill").font(.system(size: 12))
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
            .padding(.leading, 10 + safeHorizontal.leading)
            .padding(.trailing, 10 + safeHorizontal.trailing)
            .padding(.top, 10)

            // Camera trouble is always visible and always recoverable.
            if videoMode && (!camera.isReady || !camera.status.isEmpty) {
                Button {
                    Task { await restartCamera() }
                } label: {
                    HStack(spacing: 8) {
                        AppIcon("exclamationmark.triangle.fill")
                        Text(camera.status.isEmpty ? "Camera is starting…" : camera.status)
                            .font(.system(size: 13, weight: .semibold))
                        Text("Retry")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                }
            }

            Spacer()
        }
        .scaleEffect(y: interfaceFlip)
    }

    // MARK: - Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            iconButton("chevron.left", tint: Theme.accent) { exit() }
            Spacer(minLength: 0)
            if !videoMode {
                iconButton("arrow.up.arrow.down", tint: settings.mirrorV ? Theme.accent : .white.opacity(0.75)) {
                    settings.mirrorV.toggle()
                }
                Spacer(minLength: 0)
            }
            PlayPauseButton(engine: engine, size: toolbarButtonSize, action: togglePlay)
            Spacer(minLength: 0)
            if videoMode {
                Button {
                    camera.recordingRequested ? stopRecording() : startRecording()
                } label: {
                    Image(systemName: camera.recordingRequested ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: toolbarIconSize + 4, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.red)
                        .frame(width: recordButtonSize, height: recordButtonSize)
                        .background(.white.opacity(0.16), in: Circle())
                        .overlay(Circle().stroke(.red.opacity(0.55), lineWidth: 1.5))
                }
                .disabled(saving)
                .opacity(saving ? 0.4 : 1)
                Spacer(minLength: 0)
            }
            iconButton("slider.horizontal.3") { toggle(.settings) }
            Spacer(minLength: 0)
            iconButton("textformat") { toggle(.size) }
            Spacer(minLength: 0)
            iconButton("ellipsis", tint: panel == .more ? Theme.accent : .white.opacity(0.75)) { toggle(.more) }
        }
        .padding(.leading, 16 + safeHorizontal.leading)
        .padding(.trailing, 16 + safeHorizontal.trailing)
        .padding(.vertical, 12)
        .padding(.bottom, safeBottom)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.97))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.16)).frame(height: 1) }
        .scaleEffect(y: interfaceFlip)
    }

    private var safeBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
    }

    private var safeHorizontal: (leading: CGFloat, trailing: CGFloat) {
        let insets = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .first
        return (insets?.left ?? 0, insets?.right ?? 0)
    }

    /// Large, consistent targets remain readable while watching the script.
    private var toolbarButtonSize: CGFloat {
        UIScreen.main.bounds.width >= 430 ? 58 : 54
    }

    private var toolbarIconSize: CGFloat { 28 }
    private var recordButtonSize: CGFloat { toolbarButtonSize + 8 }

    private func iconButton(_ name: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: toolbarSymbol(for: name))
                .font(.system(size: toolbarIconSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: toolbarButtonSize, height: toolbarButtonSize)
                .background(.white.opacity(0.14), in: Circle())
        }
    }

    private func toolbarSymbol(for name: String) -> String {
        switch name {
        case "chevron.left": return "chevron.backward"
        case "arrow.up.arrow.down": return "arrow.up.and.down"
        case "slider.horizontal.3": return "camera.filters"
        case "textformat": return "textformat.size"
        case "ellipsis": return "ellipsis"
        default: return name
        }
    }

    private func toggle(_ p: Panel) { panel = (panel == p) ? nil : p }

    // MARK: - Popovers

    @ViewBuilder
    private func popover(for p: Panel) -> some View {
        GeometryReader { panelGeometry in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { panel = nil }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch p {
                        case .settings:
                            popRow("Speed", "\(Int(settings.speed))") {
                                Slider(value: $settings.speed, in: 10...250, step: 1)
                            }
                            popRow("Width", "\(Int(settings.textWidth))%") {
                                Slider(value: $settings.textWidth, in: 50...100, step: 1)
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

                            if videoMode {
                                Button {
                                    Task {
                                        await camera.switchCamera(quality: settings.quality, fps: settings.frameRate,
                                                                  hdr: settings.hdr, stabilization: settings.stabilization)
                                    }
                                    settings.useFrontCamera = !camera.usingFront
                                } label: {
                                    Text(camera.usingFront ? "Front camera" : "Back camera").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(OutlineButtonStyle(active: camera.usingFront))
                                .disabled(camera.recordingRequested)

                                if !camera.modes.isEmpty {
                                    Text("Resolution").font(.caption).foregroundStyle(.white.opacity(0.7))
                                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                        ForEach(camera.modes) { mode in
                                            let active = settings.quality == mode.quality
                                                && settings.frameRate == mode.fps && settings.hdr == mode.hdr
                                            Button {
                                                settings.quality = mode.quality
                                                settings.frameRate = mode.fps
                                                settings.hdr = mode.hdr
                                                Task { await restartCamera() }
                                            } label: {
                                                Text(mode.label).font(.system(size: 12, weight: .semibold))
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(OutlineButtonStyle(active: active))
                                            .disabled(camera.recordingRequested)
                                        }
                                    }

                                    let logAvailable = CameraManager.appleLogAvailable(
                                        front: settings.useFrontCamera,
                                        quality: settings.quality,
                                        fps: settings.frameRate)
                                    Toggle("Apple Log", isOn: Binding(
                                        get: { settings.appleLog && logAvailable },
                                        set: { on in
                                            settings.appleLog = on
                                            Task { await restartCamera() }
                                        }))
                                        .font(.system(size: 13, weight: .semibold))
                                        .disabled(!logAvailable || camera.recordingRequested)
                                    if logAvailable && settings.appleLog {
                                        Picker("Log codec", selection: Binding(
                                            get: { settings.logCodec },
                                            set: { value in
                                                settings.logCodec = value
                                                Task { await restartCamera() }
                                            })) {
                                                Text("ProRes 422").tag("prores")
                                                Text("HEVC").tag("hevc")
                                            }
                                            .pickerStyle(.segmented)
                                            .disabled(camera.recordingRequested)
                                        Text(settings.logCodec == "prores"
                                             ? "ProRes 422 · biggest files, maximum grading latitude"
                                             : "HEVC · much smaller files, still Apple Log")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                    if !logAvailable {
                                        Text(CameraManager.appleLogUnavailableReason)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.5))
                                    } else if !camera.appleLogDetail.isEmpty {
                                        Text(camera.appleLogDetail)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                }

                                Toggle("180° shutter angle", isOn: $settings.shutterAngle)
                                    .tint(Theme.accent)
                                Text(settings.shutterAngle
                                     ? (camera.shutterSpeedLabel.isEmpty ? "Shutter locked to double the frame rate. ISO and white balance stay auto."
                                        : "Shutter \(camera.shutterSpeedLabel) · ISO and white balance auto")
                                     : "Off for outdoors. Turn on indoors for natural motion blur.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))

                                Toggle("Stabilization", isOn: $settings.stabilization)
                                    .tint(Theme.accent)
                                    .disabled(camera.recordingRequested)

                                Toggle("Cinematic mode", isOn: .constant(false))
                                    .tint(Theme.accent)
                                    .disabled(true)
                                Text(CameraManager.cinematicUnavailableReason)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.45))

                                Text("Audio").font(.caption).foregroundStyle(.white.opacity(0.7))
                                HStack {
                                    Text(camera.micName.isEmpty ? "Built-in mic" : camera.micName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(camera.micDetail)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Theme.accent)
                                }
                                popRow("Gain", String(format: "%+.1f dB", settings.micGainDb)) {
                                    Slider(value: $settings.micGainDb,
                                           in: AudioGain.minimumDb...AudioGain.maximumDb,
                                           step: 0.5)
                                        .tint(Theme.accent)
                                        .disabled(camera.recordingRequested)
                                }
                                HStack(spacing: 10) {
                                    Button("−20 dB") { settings.micGainDb = -20 }
                                    Button("0 dB") { settings.micGainDb = 0 }
                                    Button("+20 dB") { settings.micGainDb = 20 }
                                }
                                .font(.caption2)
                                .buttonStyle(.plain)
                                .foregroundStyle(.white.opacity(0.55))
                                .disabled(camera.recordingRequested)
                                Text("Manual only — nothing adjusts itself. The meter shows the level with this gain applied; keep peaks at or below the white −12 mark.")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.45))
                            }

                            Text("Reading assist").font(.caption).foregroundStyle(.white.opacity(0.7))
                            assistRow("Chunk phrases", isOn: $settings.chunking)

                            Text("Tap the script to play / pause. Bluetooth remotes (Desview, AirTurn) work too.")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(14)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: 420)
                .frame(maxHeight: max(140, panelGeometry.size.height - 92 - safeBottom))
                .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.1)))
                .padding(.leading, 16 + safeHorizontal.leading)
                .padding(.trailing, 16 + safeHorizontal.trailing)
                .padding(.bottom, 72 + safeBottom)
                .scaleEffect(y: interfaceFlip)
            }
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

    // MARK: - Behaviour

    private var readerBackground: Color { .black }

    private func begin() async {
        IdleTimer.keepAwake(true)
        if videoMode { await restartCamera() }
        guard !didFinish else { return }
    }

    private func restartCamera() async {
        do {
            try await camera.start(
                front: settings.useFrontCamera,
                quality: settings.quality,
                fps: settings.frameRate,
                hdr: settings.hdr,
                stabilization: settings.stabilization,
                appleLog: settings.appleLog,
                logCodec: settings.logCodec
            )
            camera.setShutterAngle(settings.shutterAngle)
            // The gain chosen for the last take is reapplied automatically.
            if camera.micGainSupported { camera.setMicGain(AudioGain.hardwareValue(db: settings.micGainDb)) }
            camera.levelMonitor.gainDb = settings.micGainDb
            camera.setMeteringPaused(camera.recordingRequested)
            // Permission prompts and capture setup can finish after Back has
            // already removed this screen. Never leave that late session alive.
            if didFinish { camera.stop() }
        } catch CameraManager.CameraError.permissionDenied {
            errorMessage = "Camera access is off. Enable it in Settings to record."
        } catch {
            // Non-permission problems stay on the retry chip instead of
            // interrupting with an alert.
        }
    }





    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        engine.pause()
        if camera.recordingRequested {
            stopRecording(stopCameraWhenFinished: true)
        } else {
            camera.stop()
        }
        IdleTimer.keepAwake(false)
        settings.setReadingPosition(Double(engine.offset), for: script.id)
    }

    private func exit() {
        guard !camera.recordingRequested else { return }
        finish()
        onExit()
    }

    private func pause() {
        engine.pause()
    }

    private func play() {
        engine.speed = settings.speed
        engine.play()
    }

    private func togglePlay() {
        Haptics.tap()
        if panel != nil { panel = nil; return }
        if engine.isPlaying {
            pause()
            controlsVisible = true
        } else {
            play()
            controlsVisible = false
        }
    }

    private func startRecording() {
        // Rapid double taps, or a tap while the previous take is still being
        // written, must never reach the capture pipeline.
        guard !saving, !camera.recordingRequested, currentTakeID == nil else { return }
        let url = recordings.newRecordingURL(id: UUID().uuidString)
        let id = Self.recordingID(for: url)
        do {
            camera.setContinuationURLProvider {
                recordings.newRecordingURL(id: UUID().uuidString)
            }
            // If the system ends the take (call, alarm, backgrounding, camera
            // error) the footage already on disk is still saved to the clips.
            camera.onInvoluntaryFinish = { result in
                Task { @MainActor in
                    saving = false
                    switch result {
                    case .success(let finishedURL):
                        let segmentID = Self.recordingID(for: finishedURL)
                        // Registered first: the take is safe before the manual
                        // gain pass touches anything.
                        recordings.register(id: segmentID, url: finishedURL, title: script.displayTitle, scriptID: script.id)
                        recordings.refreshMetadata(id: segmentID)
                        let trim = settings.micGainDb
                        Task {
                            _ = await AudioGain.apply(gainDb: trim, to: finishedURL)
                            await MainActor.run { recordings.refreshMetadata(id: segmentID) }
                        }
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                    }
                    if !camera.recordingRequested {
                        currentTakeID = nil
                        controlsVisible = true
                        engine.pause()
                        camera.onInvoluntaryFinish = nil
                    }
                }
            }
            try camera.startRecording(to: url)
            currentTakeID = id
            play()
            controlsVisible = false
            panel = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording(stopCameraWhenFinished: Bool = false) {
        guard camera.recordingRequested, !saving else { return }
        saving = true
        pause()
        controlsVisible = true
        let id = currentTakeID ?? UUID().uuidString
        camera.stopRecording { result in
            Task { @MainActor in
                saving = false
                switch result {
                case .success(let url):
                    let finishedID = Self.recordingID(for: url)
                    // Registered first: the take is safe before the manual gain
                    // pass touches anything.
                    recordings.register(id: finishedID, url: url, title: script.displayTitle, scriptID: script.id)
                    recordings.refreshMetadata(id: finishedID)
                    let trim = settings.micGainDb
                    Task {
                        _ = await AudioGain.apply(gainDb: trim, to: url)
                        await MainActor.run { recordings.refreshMetadata(id: finishedID) }
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
                currentTakeID = nil
                camera.onInvoluntaryFinish = nil
                if stopCameraWhenFinished { camera.stop() }
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
            camera.recordingRequested ? stopRecording() : startRecording()
        }
    }

    private static func recordingID(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.hasPrefix("take-") ? String(name.dropFirst(5)) : name
    }
}

// MARK: - Engine-observing subviews

/// Only this view redraws on every scroll frame.
private struct ScriptScrollLayer: View {
    @ObservedObject var engine: TeleprompterEngine

    let document: ScriptDocument
    let fontSize: Double
    let lineHeight: Double
    let textWidth: Double
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    let foreground: Color
    let mirrorH: Bool
    let flip: CGFloat
    let onContentHeight: (CGFloat) -> Void

    var body: some View {
        // LOCKED READING TYPOGRAPHY — matches the web app: weight 500,
        // line-height 1.5, -0.015em tracking, words never split.
        ZStack(alignment: .top) {
            NativeScriptTextView(
                document: document,
                fontSize: fontSize,
                lineHeight: lineHeight,
                foreground: foreground,
                scrollOffset: engine.offset,
                viewportHeight: viewportHeight,
                onContentHeight: onContentHeight
            )
            .frame(width: viewportWidth * textWidth / 100, alignment: .leading)
            .scaleEffect(x: mirrorH ? -1 : 1, y: flip, anchor: .top)
        }
        .frame(width: viewportWidth, height: viewportHeight, alignment: .top)
        .clipped()
        .allowsHitTesting(false)
    }
}

private struct PlayPauseButton: View {
    @ObservedObject var engine: TeleprompterEngine
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .frame(width: size, height: size)
                .background(.white.opacity(0.14), in: Circle())
        }
    }
}

private struct ProgressLine: View {
    @ObservedObject var engine: TeleprompterEngine

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Color.white.opacity(0.1)
                Theme.accent.frame(width: proxy.size.width * engine.progress)
            }
        }
        .frame(height: 2)
    }
}

private struct RemainingBadge: View {
    @ObservedObject var engine: TeleprompterEngine

    var body: some View {
        Text("\(max(0, 100 - Int((engine.progress * 100).rounded())))% left")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
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
