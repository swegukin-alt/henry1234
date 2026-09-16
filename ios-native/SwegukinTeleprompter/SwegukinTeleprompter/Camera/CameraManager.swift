import Foundation
import AVFoundation
import UIKit
import Combine

struct CaptureMode: Identifiable, Hashable {
    var quality: String      // "720p" | "1080p" | "4k"
    var width: Int
    var height: Int
    var fps: Int
    var hdr: Bool
    var stabilization: Bool

    var id: String { "\(quality)-\(fps)-\(hdr ? 1 : 0)" }
    var label: String { "\(quality == "4k" ? "4K" : quality) · \(fps)fps\(hdr ? " · HDR" : "")" }
}


@MainActor
final class CameraManager: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    /// Human readable state shown on the prompter when something is wrong.
    @Published private(set) var status: String = ""
    @Published private(set) var modes: [CaptureMode] = []
    @Published private(set) var micName: String = ""
    @Published var zoom: CGFloat = 1 { didSet { applyZoom() } }
    @Published private(set) var torchOn = false
    @Published private(set) var usingFront = true
    @Published private(set) var previewRotationAngle: CGFloat = 90



    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice? { videoInput?.device }
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    

    private weak var attachedPreviewLayer: AVCaptureVideoPreviewLayer?
    private var timer: Timer?
    private var startedAt: Date?
    private var pendingCompletion: ((Result<URL, Error>) -> Void)?
    private var observing = false

    /// Called when a take ends without the user pressing stop (system
    /// interruption, backgrounding, capture error). The footage already written
    /// to disk is handed over so it is always kept.
    var onInvoluntaryFinish: ((Result<URL, Error>) -> Void)?

    enum CameraError: LocalizedError {
        case noDevice, notReady, alreadyRecording, permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDevice: return "No camera available on this device."
            case .notReady: return "The camera is not running yet."
            case .alreadyRecording: return "Already recording."
            case .permissionDenied: return "Camera access is turned off. Enable it in Settings."
            }
        }
    }

    // MARK: - Lifecycle

    /// Starting the camera never fails for a format reason. The session comes up
    /// with a preset the hardware always supports, then the requested
    /// resolution / frame rate / HDR is applied as a best effort on top.
    func start(front: Bool, quality: String, fps: Int, hdr: Bool, stabilization: Bool) async throws {
        if PermissionManager.cameraState() == .undetermined {
            _ = await PermissionManager.requestCamera()
        }
        if PermissionManager.microphoneState() == .undetermined {
            _ = await PermissionManager.requestMicrophone()
        }
        guard PermissionManager.cameraState() == .granted else {
            status = "Camera access is off. Enable it in Settings."
            throw CameraError.permissionDenied
        }

        AudioSessionManager.shared.activateForCapture()
        AudioSessionManager.shared.onRouteChange = { [weak self] name in
            self?.micName = name
        }
        // An alarm or phone call takes the microphone for a moment. Bring the
        // capture audio session straight back instead of ending the take.
        AudioSessionManager.shared.onInterruptionEnded = { [weak self] in
            Task { @MainActor in
                AudioSessionManager.shared.activateForCapture()
                self?.micName = AudioSessionManager.shared.currentInputName
            }
        }
        micName = AudioSessionManager.shared.currentInputName
        usingFront = front
        status = ""

        let running: Bool = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { return continuation.resume(returning: false) }
                let ok = self.configure(front: front, quality: quality, fps: fps, hdr: hdr, stabilization: stabilization)
                if ok, !self.session.isRunning { self.session.startRunning() }
                continuation.resume(returning: ok && self.session.isRunning)
            }
        }

        observeSession()
        isReady = running
        if !running {
            status = status.isEmpty ? "Camera could not start. Tap retry." : status
            throw CameraError.noDevice
        }
        modes = Self.supportedModes(for: device)
        makeRotationCoordinator()
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        isReady = false
        AudioSessionManager.shared.deactivate()
    }

    /// Called by the preview view so rotation follows the real hardware horizon.
    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        attachedPreviewLayer = previewLayer
        makeRotationCoordinator()
    }

    private func makeRotationCoordinator() {
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: attachedPreviewLayer)
        rotationCoordinator = coordinator
        previewRotationAngle = Self.interfaceRotationAngle()
    }

    func refreshRotation() {
        let angle = Self.interfaceRotationAngle()
        if angle != previewRotationAngle { previewRotationAngle = angle }
    }


    /// Use the window's settled interface orientation rather than the raw
    /// device orientation. The latter briefly reports face-up/unknown while an
    /// iPhone is being turned and left the preview sideways inside a portrait
    /// frame, which looked like an extreme digital zoom.
    private static func interfaceRotationAngle() -> CGFloat {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first
        switch orientation {
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    // MARK: - Configuration

    /// Runs on the session queue. Returns false only when there is genuinely no
    /// usable camera input.
    private func configure(front: Bool, quality: String, fps: Int, hdr: Bool, stabilization: Bool) -> Bool {
        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.automaticallyConfiguresCaptureDeviceForWideColor = true


        for input in session.inputs { session.removeInput(input) }
        videoInput = nil
        audioInput = nil

        guard let camera = Self.pickCamera(front: front),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            status = "No camera available on this device."
            return false
        }
        session.addInput(input)
        videoInput = input

        // Always begin at the physical 1× field of view. A zoom value can be
        // retained by AVFoundation across format changes on multi-camera phones.
        if (try? camera.lockForConfiguration()) != nil {
            camera.videoZoomFactor = max(camera.minAvailableVideoZoomFactor, 1)
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            camera.isSubjectAreaChangeMonitoringEnabled = true
            camera.unlockForConfiguration()
        }

        // A preset the hardware is guaranteed to support keeps the preview alive
        // even when the requested mode is not offered by this camera.
        let preset = Self.preset(for: quality)
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        // Audio is optional for the preview: a missing mic must never black out
        // the camera.
        if let mic = AVCaptureDevice.default(for: .audio),
           let aInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(aInput) {
            session.addInput(aInput)
            audioInput = aInput
        }

        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        movieOutput.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 1)

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stabilization ? .auto : .off
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        session.commitConfiguration()

        // Best-effort refinement once the session is valid.
        Self.applyFormat(on: camera, quality: quality, fps: fps, hdr: hdr)
        return true
    }

    private static func preset(for quality: String) -> AVCaptureSession.Preset {
        switch quality {
        case "720p": return .hd1280x720
        case "4k": return .hd4K3840x2160
        default: return .hd1920x1080
        }
    }

    /// Only combinations the hardware actually reports — nothing invented, and a
    /// miss simply leaves the working preset in place.
    private static func applyFormat(on camera: AVCaptureDevice, quality: String, fps: Int, hdr: Bool) {
        let target = dimensions(for: quality)
        let candidates = camera.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.width) == target.width, Int(dims.height) == target.height else { return false }
            guard format.videoSupportedFrameRateRanges.contains(where: {
                Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate
            }) else { return false }
            if hdr { return format.isVideoHDRSupported }
            return true
        }
        // Several formats can have identical dimensions and frame rates but a
        // different field of view. Choose the widest one to match the web
        // camera and avoid an apparently zoomed-in preview.
        guard let format = candidates.max(by: { $0.videoFieldOfView < $1.videoFieldOfView }) else { return }
        guard (try? camera.lockForConfiguration()) != nil else { return }
        camera.activeFormat = format
        camera.videoZoomFactor = max(camera.minAvailableVideoZoomFactor, 1)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        camera.activeVideoMinFrameDuration = frameDuration
        camera.activeVideoMaxFrameDuration = frameDuration
        if format.isVideoHDRSupported {
            camera.automaticallyAdjustsVideoHDREnabled = false
            camera.isVideoHDREnabled = hdr
        }
        camera.unlockForConfiguration()
    }

    static func dimensions(for quality: String) -> (width: Int, height: Int) {
        switch quality {
        case "720p": return (1280, 720)
        case "4k": return (3840, 2160)
        default: return (1920, 1080)
        }
    }

    /// Reads the exact modes this iPhone's camera reports.
    static func supportedModes(for device: AVCaptureDevice?) -> [CaptureMode] {
        guard let device else { return [] }
        var found: [String: CaptureMode] = [:]
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let quality: String
            switch (Int(dims.width), Int(dims.height)) {
            case (1280, 720): quality = "720p"
            case (1920, 1080): quality = "1080p"
            case (3840, 2160): quality = "4k"
            default: continue
            }
            for range in format.videoSupportedFrameRateRanges {
                for fps in [30, 60] where Double(fps) >= range.minFrameRate && Double(fps) <= range.maxFrameRate {
                    let sdr = CaptureMode(quality: quality, width: Int(dims.width), height: Int(dims.height),
                                          fps: fps, hdr: false, stabilization: true)
                    found[sdr.id] = sdr
                    if format.isVideoHDRSupported {
                        let hdr = CaptureMode(quality: quality, width: Int(dims.width), height: Int(dims.height),
                                              fps: fps, hdr: true, stabilization: true)
                        found[hdr.id] = hdr
                    }
                }
            }
        }
        return found.values.sorted {
            ($0.width, $0.fps, $0.hdr ? 1 : 0) < ($1.width, $1.fps, $1.hdr ? 1 : 0)
        }
    }

    /// Widest available front camera, or the best rear camera.
    private static func pickCamera(front: Bool) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = front ? .front : .back
        let types: [AVCaptureDevice.DeviceType] = front
            ? [.builtInWideAngleCamera]
            : [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        return discovery.devices.first
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    /// Camera modes are available before entering video mode, so the editor's
    /// native camera menu never depends on an already-running capture session.
    static func availableModes(front: Bool) -> [CaptureMode] {
        supportedModes(for: pickCamera(front: front))
    }

    // MARK: - Cinematic

    /// Cinematic video capture is not part of this recorder. Apple's Cinematic
    /// pipeline is a separate capture path, so the row stays disabled with a
    /// reason rather than pretending to do something.
    static let cinematicUnavailableReason = "Requires Apple's Cinematic capture pipeline."



    /// Stabilization can be toggled while the camera is live; applying it to the
    /// existing connection avoids restarting capture.
    func setStabilization(_ on: Bool) {
        let output = movieOutput
        sessionQueue.async {
            guard let connection = output.connection(with: .video),
                  connection.isVideoStabilizationSupported else { return }
            connection.preferredVideoStabilizationMode = on ? .auto : .off
        }
    }






    // MARK: - Controls

    func switchCamera(quality: String, fps: Int, hdr: Bool, stabilization: Bool) async {
        guard !isRecording else { return }
        try? await start(front: !usingFront, quality: quality, fps: fps, hdr: hdr, stabilization: stabilization)
    }

    private func applyZoom() {
        guard let device else { return }
        let clamped = max(1, min(zoom, min(device.activeFormat.videoMaxZoomFactor, 8)))
        sessionQueue.async {
            try? device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        }
    }

    func focus(at point: CGPoint) {
        guard let device else { return }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            device.unlockForConfiguration()
        }
    }

    func toggleTorch() {
        guard let device, device.hasTorch else { return }
        let next = !torchOn
        sessionQueue.async { [weak self] in
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = next ? .on : .off
            device.unlockForConfiguration()
            Task { @MainActor in self?.torchOn = next }
        }
    }

    // MARK: - Recording

    func startRecording(to url: URL) throws {
        guard session.isRunning else { throw CameraError.notReady }
        guard !movieOutput.isRecording, !isRecording else { throw CameraError.alreadyRecording }
        // A previous take is still being closed: starting now would drop it.
        guard !isFinishing else { throw CameraError.busy }
        guard movieOutput.connection(with: .video) != nil else { throw CameraError.notReady }
        guard Self.hasRoomToRecord() else { throw CameraError.noSpace }

        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw CameraError.notReady }

        if let connection = movieOutput.connection(with: .video) {
            let angle = Self.interfaceRotationAngle()
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        try? FileManager.default.removeItem(at: url)
        currentFileURL = url
        isFinishing = false
        startedAt = Date()
        elapsed = 0
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        Haptics.strong()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard movieOutput.isRecording else {
            // The system already closed the file (interruption, error). Hand
            // back whatever finished writing instead of reporting a failure.
            if let url = currentFileURL, FileManager.default.fileExists(atPath: url.path) {
                completion(.success(url))
            } else {
                completion(.failure(CameraError.notReady))
            }
            return
        }
        // A second press while the file is closing must never start a new stop.
        if isFinishing, pendingCompletion != nil { return }
        pendingCompletion = completion
        isFinishing = true
        movieOutput.stopRecording()

        // Safety net: if AVFoundation never calls back, keep the footage and
        // free the UI instead of leaving the app stuck in "saving".
        stopWatchdog?.invalidate()
        stopWatchdog = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let completion = self.pendingCompletion else { return }
                self.pendingCompletion = nil
                self.isFinishing = false
                self.isRecording = false
                self.timer?.invalidate()
                self.timer = nil
                if let url = self.currentFileURL, FileManager.default.fileExists(atPath: url.path) {
                    completion(.success(url))
                } else {
                    completion(.failure(CameraError.notReady))
                }
            }
        }
    }

    // MARK: - Session health

    private func observeSession() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = "Camera error — restarting"
                self.finalizeIfRecording()
                self.sessionQueue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    Task { @MainActor in
                        self.isReady = self.session.isRunning
                        if self.isReady { self.status = "" }
                    }
                }
            }
        }
        center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = "Camera interrupted"
                // A call, alarm or the camera being taken away ends capture at
                // the hardware level. Close the file cleanly so the take that
                // was already written to disk is never lost.
                self.finalizeIfRecording()
            }
        }
        center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = ""
                self.sessionQueue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    Task { @MainActor in self.isReady = self.session.isRunning }
                }
            }
        }
    }

    /// Closes an in-flight take without the user pressing stop. The delegate
    /// hands the finished file to `onInvoluntaryFinish` so it is saved.
    func finalizeIfRecording() {
        guard movieOutput.isRecording, !isFinishing else { return }
        isFinishing = true
        movieOutput.stopRecording()
    }

    /// Refuses to start a take that the disk cannot hold.
    private static func hasRoomToRecord() -> Bool {
        let values = try? AppPaths.recordings.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > 300_000_000
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            self.timer?.invalidate()
            self.timer = nil
            self.isRecording = false
            self.isFinishing = false
            self.stopWatchdog?.invalidate()
            self.stopWatchdog = nil
            self.startedAt = nil

            let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            // AVFoundation flags a stopped-early recording but still leaves a
            // playable file on disk — keep it rather than losing the take.
            let result: Result<URL, Error>
            if let error, !fileExists || size == 0 {
                Haptics.failure()
                self.status = error.localizedDescription
                result = .failure(error)
            } else {
                Haptics.success()
                result = .success(outputFileURL)
            }

            if let completion = self.pendingCompletion {
                self.pendingCompletion = nil
                completion(result)
            } else {
                // Nobody asked for this stop: the system ended the take. Hand
                // the footage over so it still lands in the clip list.
                self.onInvoluntaryFinish?(result)
            }
        }
    }
}
