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
    @Published private(set) var status: String = ""
    @Published private(set) var modes: [CaptureMode] = []
    @Published private(set) var micName: String = ""
    @Published var zoom: CGFloat = 1 { didSet { applyZoom() } }
    @Published private(set) var torchOn = false
    @Published private(set) var usingFront = true

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice? { videoInput?.device }
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var timer: Timer?
    private var startedAt: Date?
    private var pendingCompletion: ((Result<URL, Error>) -> Void)?
    private var currentFileURL: URL?

    /// Preview angle, driven by the real hardware/horizon coordinator.
    @Published private(set) var previewRotationAngle: CGFloat = 90

    enum CameraError: LocalizedError {
        case noDevice, notReady, alreadyRecording, permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDevice: return "No camera available on this device."
            case .notReady: return "The camera is not running yet."
            case .alreadyRecording: return "Already recording."
            case .permissionDenied: return "Camera or microphone access is turned off in Settings."
            }
        }
    }

    // MARK: - Lifecycle

    func start(front: Bool, quality: String, fps: Int, hdr: Bool, stabilization: Bool) async throws {
        if PermissionManager.cameraState() == .undetermined {
            _ = await PermissionManager.requestCamera()
        }
        if PermissionManager.microphoneState() == .undetermined {
            _ = await PermissionManager.requestMicrophone()
        }
        guard PermissionManager.cameraState() == .granted else { throw CameraError.permissionDenied }

        AudioSessionManager.shared.activateForCapture()
        AudioSessionManager.shared.onRouteChange = { [weak self] name in
            self?.micName = name
        }
        AudioSessionManager.shared.onInterruptionBegan = { [weak self] in
            self?.status = "Audio interrupted"
        }
        micName = AudioSessionManager.shared.currentInputName
        usingFront = front

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.configure(front: front, quality: quality, fps: fps, hdr: hdr, stabilization: stabilization)
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        observeSession()
        if let device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinator = coordinator
            previewRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        }
        modes = Self.supportedModes(for: device)
        isReady = true
        status = ""
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        isReady = false
        AudioSessionManager.shared.deactivate()
    }

    func refreshRotation() {
        guard let coordinator = rotationCoordinator else { return }
        previewRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
    }

    // MARK: - Configuration

    private func configure(front: Bool, quality: String, fps: Int, hdr: Bool, stabilization: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.automaticallyConfiguresApplicationAudioSession = false

        if let existing = videoInput {
            session.removeInput(existing)
            videoInput = nil
        }
        guard let camera = Self.pickCamera(front: front) else { throw CameraError.noDevice }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraError.noDevice }
        session.addInput(input)
        videoInput = input

        if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
           let aInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(aInput) {
            session.addInput(aInput)
            audioInput = aInput
        }

        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        movieOutput.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 1)

        applyFormat(on: camera, quality: quality, fps: fps, hdr: hdr)

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stabilization ? .auto : .off
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = front
            }
        }
    }

    /// Only combinations the hardware actually reports — nothing invented.
    private func applyFormat(on camera: AVCaptureDevice, quality: String, fps: Int, hdr: Bool) {
        let target = Self.dimensions(for: quality)
        let candidates = camera.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.width) == target.width, Int(dims.height) == target.height else { return false }
            guard format.videoSupportedFrameRateRanges.contains(where: {
                Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate
            }) else { return false }
            if hdr { return format.isVideoHDRSupported }
            return true
        }
        let chosen = candidates.first { !hdr ? !$0.isVideoHDRSupported : true } ?? candidates.first
        guard let format = chosen else { return }
        do {
            try camera.lockForConfiguration()
            camera.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            camera.activeVideoMinFrameDuration = frameDuration
            camera.activeVideoMaxFrameDuration = frameDuration
            if format.isVideoHDRSupported {
                camera.automaticallyAdjustsVideoHDREnabled = false
                camera.isVideoHDREnabled = hdr
            }
            camera.unlockForConfiguration()
        } catch {
            NSLog("[Camera] format lock failed: \(error.localizedDescription)")
        }
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
                    let mode = CaptureMode(
                        quality: quality,
                        width: Int(dims.width),
                        height: Int(dims.height),
                        fps: fps,
                        hdr: format.isVideoHDRSupported,
                        stabilization: !format.videoSupportedFrameRateRanges.isEmpty
                    )
                    let key = "\(quality)-\(fps)-\(mode.hdr)"
                    if found[key] == nil { found[key] = mode }
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
            ? [.builtInWideAngleCamera, .builtInTrueDepthCamera]
            : [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        return discovery.devices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    // MARK: - Controls

    func switchCamera(quality: String, fps: Int, hdr: Bool, stabilization: Bool) async {
        guard !isRecording else { return }
        usingFront.toggle()
        try? await start(front: usingFront, quality: quality, fps: fps, hdr: hdr, stabilization: stabilization)
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
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
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
        guard isReady, session.isRunning else { throw CameraError.notReady }
        guard !movieOutput.isRecording else { throw CameraError.alreadyRecording }

        if let connection = movieOutput.connection(with: .video) {
            let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
        try? FileManager.default.removeItem(at: url)
        currentFileURL = url
        startedAt = Date()
        elapsed = 0
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        Haptics.strong()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard movieOutput.isRecording else {
            completion(.failure(CameraError.notReady))
            return
        }
        pendingCompletion = completion
        movieOutput.stopRecording()
    }

    // MARK: - Session health

    private func observeSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.status = "Camera error — restarting"
                self?.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    if !self.session.isRunning { self.session.startRunning() }
                }
            }
        }
        center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.status = "Camera interrupted" }
        }
        center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.status = "" }
        }
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
            self.startedAt = nil

            let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
            // AVFoundation flags a stopped-early recording but still leaves a
            // playable file on disk — keep it rather than losing the take.
            if let error, !fileExists {
                Haptics.failure()
                self.status = error.localizedDescription
                self.pendingCompletion?(.failure(error))
            } else {
                Haptics.success()
                self.pendingCompletion?(.success(outputFileURL))
            }
            self.pendingCompletion = nil
            self.currentFileURL = nil
        }
    }
}
