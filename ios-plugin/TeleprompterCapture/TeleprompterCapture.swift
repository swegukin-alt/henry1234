import AVFoundation
import Foundation
import UIKit

/// AVFoundation capture for the teleprompter: a preview layer behind the
/// WebView, video+audio recorded straight to a file, plus the audio-session
/// control (external mics, route changes, interruptions) the app needs.
@objc public class TeleprompterCapture: NSObject, AVCaptureFileOutputRecordingDelegate {

    public enum CaptureError: LocalizedError {
        case noCamera, noMicrophone, notRunning, alreadyRecording

        public var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera is available."
            case .noMicrophone: return "No microphone is available."
            case .notRunning: return "The camera preview is not running."
            case .alreadyRecording: return "A recording is already in progress."
            }
        }
    }

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()
    private var recordingStartedAt: Date?
    private var stopCompletion: ((URL?, Error?) -> Void)?

    /// Fired back into JavaScript.
    public var onInterruption: ((String) -> Void)?
    public var onRouteChange: ((String) -> Void)?

    // MARK: - Permissions

    public static func cameraStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "prompt"
        }
    }

    public static func microphoneStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "prompt"
        }
    }

    public static func request(_ media: AVMediaType, _ done: @escaping (String) -> Void) {
        AVCaptureDevice.requestAccess(for: media) { granted in
            DispatchQueue.main.async { done(granted ? "granted" : "denied") }
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        // .videoRecording keeps iOS from applying voice-chat processing, and
        // these options let a wired/USB or Bluetooth mic be the input.
        try s.setCategory(.playAndRecord,
                          mode: .videoRecording,
                          options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers])
        try s.setActive(true, options: [])
    }

    private func observeAudio() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self?.onInterruption?(type == .began ? "began" : "ended")
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onRouteChange?(self?.currentRouteName() ?? "unknown")
        }
    }

    public func currentRouteName() -> String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "none"
    }

    public func audioInputs() -> [[String: Any]] {
        let available = AVAudioSession.sharedInstance().availableInputs ?? []
        return available.map { port in
            let external = port.portType != .builtInMic
            return [
                "deviceId": port.uid,
                "label": port.portName,
                "external": external,
                "available": true
            ]
        }
    }

    public func audioStatus() -> [String: Any] {
        let current = AVAudioSession.sharedInstance().currentRoute.inputs.first
        return [
            "deviceId": current?.uid ?? "",
            "label": current?.portName ?? "",
            "external": current != nil && current!.portType != .builtInMic,
            "available": current != nil,
            "route": currentRouteName()
        ]
    }

    public func setAudioInput(deviceId: String) throws {
        let s = AVAudioSession.sharedInstance()
        guard let port = (s.availableInputs ?? []).first(where: { $0.uid == deviceId }) else {
            throw CaptureError.noMicrophone
        }
        try s.setPreferredInput(port)
    }

    // MARK: - Preview

    @discardableResult
    public func startPreview(in view: UIView, position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) throws -> CGSize {
        try configureAudioSession()
        observeAudio()

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high

        if let existing = videoInput { session.removeInput(existing) }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video) else { throw CaptureError.noCamera }
        let vIn = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(vIn) { session.addInput(vIn); videoInput = vIn }

        if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio) {
            let aIn = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(aIn) { session.addInput(aIn); audioInput = aIn }
        }

        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        session.commitConfiguration()

        let layer = previewLayer ?? AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        if layer.superlayer == nil { view.layer.insertSublayer(layer, at: 0) }
        previewLayer = layer

        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
    }

    public func stopPreview() {
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    public func flip(to position: AVCaptureDevice.Position) throws {
        guard session.isRunning else { throw CaptureError.notRunning }
        session.beginConfiguration()
        if let existing = videoInput { session.removeInput(existing) }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            session.commitConfiguration()
            throw CaptureError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) { session.addInput(input); videoInput = input }
        session.commitConfiguration()
    }

    public func setZoom(_ zoom: CGFloat) throws {
        guard let device = videoInput?.device else { throw CaptureError.notRunning }
        try device.lockForConfiguration()
        device.videoZoomFactor = max(1.0, min(zoom, device.activeFormat.videoMaxZoomFactor))
        device.unlockForConfiguration()
    }

    public func setTorch(_ on: Bool) throws {
        guard let device = videoInput?.device, device.hasTorch else { return }
        try device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    // MARK: - Recording

    public var isRecording: Bool { movieOutput.isRecording }

    public var recordedDurationMs: Int {
        guard let started = recordingStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    public func startRecording(videoBitrate: Int?, audioBitrate: Int?) throws {
        guard session.isRunning else { throw CaptureError.notRunning }
        guard !movieOutput.isRecording else { throw CaptureError.alreadyRecording }
        if let connection = movieOutput.connection(with: .video) {
            var settings = movieOutput.recommendedVideoSettingsForVideoCodecType(.h264, assetWriterOutputFileType: .mp4) ?? [:]
            if let bitrate = videoBitrate {
                var props = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
                props[AVVideoAverageBitRateKey] = bitrate
                settings[AVVideoCompressionPropertiesKey] = props
            }
            movieOutput.setOutputSettings(settings, for: connection)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("take-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        recordingStartedAt = Date()
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    public func stopRecording(_ completion: @escaping (URL?, Error?) -> Void) {
        guard movieOutput.isRecording else {
            completion(nil, CaptureError.notRunning)
            return
        }
        stopCompletion = completion
        movieOutput.stopRecording()
    }

    public func fileOutput(_ output: AVCaptureFileOutput,
                           didFinishRecordingTo outputFileURL: URL,
                           from connections: [AVCaptureConnection],
                           error: Error?) {
        let done = stopCompletion
        stopCompletion = nil
        recordingStartedAt = nil
        // Even on an interruption iOS leaves a valid, playable file behind:
        // hand it over rather than losing the take.
        let exists = FileManager.default.fileExists(atPath: outputFileURL.path)
        if exists {
            done?(outputFileURL, nil)
        } else {
            done?(nil, error ?? CaptureError.notRunning)
        }
    }
}
