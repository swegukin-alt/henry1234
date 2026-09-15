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
    /// A dedicated view behind the WebView. It resizes with its parent, so the
    /// picture survives rotation instead of staying at the launch size.
    private var previewView: UIView?
    private var stabilization: AVCaptureVideoStabilizationMode = .auto
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
    public func startPreview(in view: UIView,
                             position: AVCaptureDevice.Position,
                             preset: AVCaptureSession.Preset,
                             targetHeight: Int,
                             fps: Int,
                             hdr: Bool,
                             stabilization stabilizationName: String) throws -> CGSize {
        try configureAudioSession()
        observeAudio()

        self.stabilization = Self.stabilizationMode(stabilizationName)

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high

        if let existing = videoInput { session.removeInput(existing) }
        guard let camera = Self.bestCamera(position: position) else { throw CaptureError.noCamera }
        let vIn = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(vIn) { session.addInput(vIn); videoInput = vIn }

        if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio) {
            let aIn = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(aIn) { session.addInput(aIn); audioInput = aIn }
        }

        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()

        // Exact format control (resolution + frame rate + HDR) has to happen
        // after the session is configured, and overrides the preset.
        applyFormat(on: camera, height: targetHeight, fps: fps, hdr: hdr)
        applyStabilization()

        let host = previewView ?? {
            let v = UIView(frame: view.bounds)
            v.backgroundColor = .black
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(v, at: 0)
            previewView = v
            return v
        }()
        host.frame = view.bounds

        let layer = previewLayer ?? AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = host.bounds
        if layer.superlayer == nil { host.layer.addSublayer(layer) }
        previewLayer = layer

        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
    }

    /// Keeps the picture matching the view after a rotation.
    public func layoutPreview(in view: UIView) {
        previewView?.frame = view.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = previewView?.bounds ?? view.bounds
        if let connection = previewLayer?.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = Self.currentVideoOrientation()
        }
        CATransaction.commit()
    }

    private static func currentVideoOrientation() -> AVCaptureVideoOrientation {
        switch UIApplication.shared.windows.first?.windowScene?.interfaceOrientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    /// The widest, highest-quality front/rear camera this iPhone has.
    private static func bestCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if position == .back {
            types = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        return discovery.devices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private static func stabilizationMode(_ name: String) -> AVCaptureVideoStabilizationMode {
        switch name {
        case "off": return .off
        case "standard": return .standard
        case "cinematic": return .cinematicExtended
        default: return .auto
        }
    }

    private func applyStabilization() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = stabilization
        }
    }

    /// Picks the hardware format that matches the requested resolution, frame
    /// rate and HDR — this is what gives 4K60 and 10-bit HDR, which a plain
    /// session preset cannot reach.
    private func applyFormat(on device: AVCaptureDevice, height: Int, fps: Int, hdr: Bool) {
        let wanted = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.height) == height else { return false }
            let supportsFps = format.videoSupportedFrameRateRanges.contains { Double(fps) <= $0.maxFrameRate + 0.1 }
            guard supportsFps else { return false }
            if hdr {
                if #available(iOS 14.1, *) { return !format.supportedColorSpaces.filter { $0 == .HLG_BT2020 }.isEmpty }
                return format.isVideoHDRSupported
            }
            return true
        }
        // Prefer the widest field of view at that resolution.
        let chosen = wanted.max { a, b in
            CMVideoFormatDescriptionGetDimensions(a.formatDescription).width <
            CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
        }
        guard let format = chosen else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTimeMake(value: 1, timescale: Int32(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            if #available(iOS 14.1, *), hdr, format.supportedColorSpaces.contains(.HLG_BT2020) {
                device.activeColorSpace = .HLG_BT2020
            }
            if format.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = !hdr
                if hdr { device.isVideoHDREnabled = true }
            }
            device.unlockForConfiguration()
        } catch {
            // A refused format must never take the camera down: the preset stands.
        }
    }

    /// What this exact iPhone can do — read from the hardware, never guessed.
    public func deviceCapabilities() -> [String: Any] {
        guard let device = videoInput?.device ?? Self.bestCamera(position: .front) else {
            return ["resolutions": ["1080p"], "frameRates": [30], "hdr": false,
                    "stabilization": ["off"], "maxZoom": 1]
        }
        var heights = Set<Int>()
        var rates = Set<Int>()
        var hdr = false
        let activeHeight = Int(CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).height)
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            heights.insert(Int(dims.height))
            if Int(dims.height) == activeHeight {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate >= 59.9 { rates.insert(60) }
                    if range.maxFrameRate >= 29.9 { rates.insert(30) }
                }
            }
            if format.isVideoHDRSupported { hdr = true }
            if #available(iOS 14.1, *), format.supportedColorSpaces.contains(.HLG_BT2020) { hdr = true }
        }
        var resolutions: [String] = []
        if heights.contains(720) { resolutions.append("720p") }
        if heights.contains(1080) { resolutions.append("1080p") }
        if heights.contains(2160) { resolutions.append("4k") }
        if resolutions.isEmpty { resolutions = ["1080p"] }

        var modes = ["off"]
        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            modes.append(contentsOf: ["standard", "cinematic", "auto"])
        }
        return [
            "resolutions": resolutions,
            "frameRates": rates.isEmpty ? [30] : rates.sorted(),
            "hdr": hdr,
            "stabilization": modes,
            "maxZoom": Double(device.activeFormat.videoMaxZoomFactor)
        ]
    }

    public func stopPreview() {
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        previewView?.removeFromSuperview()
        previewView = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    public func flip(to position: AVCaptureDevice.Position) throws {
        guard session.isRunning else { throw CaptureError.notRunning }
        session.beginConfiguration()
        if let existing = videoInput { session.removeInput(existing) }
        guard let camera = Self.bestCamera(position: position) else {
            session.commitConfiguration()
            throw CaptureError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) { session.addInput(input); videoInput = input }
        session.commitConfiguration()
        applyStabilization()
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
            // HEVC keeps 4K60 and HDR at a sane file size; H.264 stays the
            // safest choice for everything else.
            let codec: AVVideoCodecType = movieOutput.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
            var settings = movieOutput.recommendedVideoSettingsForVideoCodecType(codec, assetWriterOutputFileType: .mp4) ?? [:]
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
