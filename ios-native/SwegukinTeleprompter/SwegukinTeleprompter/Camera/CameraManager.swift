import Foundation
import AVFoundation
import OSLog
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
    /// "USB-C · 48 kHz · 2 ch" — what the connected microphone is delivering.
    @Published private(set) var micDetail: String = ""
    /// True only when iOS exposes a hardware input-gain control for this mic.
    @Published private(set) var micGainSupported = false
    @Published var zoom: CGFloat = 1 { didSet { applyZoom() } }
    @Published private(set) var torchOn = false
    @Published private(set) var usingFront = true
    @Published private(set) var previewRotationAngle: CGFloat = 90
    /// True only when the device really reports activeColorSpace == .appleLog.
    @Published private(set) var appleLogActive = false
    /// Plain-language state for the Apple Log row.
    @Published private(set) var appleLogDetail: String = ""
    /// The codec the movie output is actually writing with.
    @Published private(set) var recordingCodecName: String = "device default"

    static let log = Logger(subsystem: "com.swegukin.teleprompter", category: "capture")



    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()
    /// Pre-recording level metering only — never part of the written file.
    let levelMonitor = AudioLevelMonitor()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let audioMeterQueue = DispatchQueue(label: "camera.audio.meter")
    /// Live HEVC Log recording: 10-bit camera frames → LogHEVCWriter.
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataQueue = DispatchQueue(label: "camera.video.data")
    private let sampleRouter = LiveSampleRouter()
    private var usesLiveHEVC = false
    private var liveWriter: LogHEVCWriter?
    private var liveFormat: (width: Int, height: Int, fps: Int) = (1920, 1080, 30)
    /// Takes written live at the exact bitrate (gain already applied).
    private var liveFileURLs = Set<URL>()
    func wasWrittenLive(_ url: URL) -> Bool { liveFileURLs.contains(url) }
    private var activeVideoConnection: AVCaptureConnection? {
        usesLiveHEVC ? videoDataOutput.connection(with: .video) : movieOutput.connection(with: .video)
    }
    private var outputIsWriting: Bool { liveWriter != nil || movieOutput.isRecording }
    private var device: AVCaptureDevice? { videoInput?.device }
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    

    private weak var attachedPreviewLayer: AVCaptureVideoPreviewLayer?
    private var timer: Timer?
    private var startedAt: Date?
    private var elapsedBeforeCurrentSegment: Double = 0
    private var pendingCompletion: ((Result<URL, Error>) -> Void)?
    private var observing = false
    /// True between asking the file to close and the delegate confirming it.
    private var isFinishing = false
    private var stopWatchdog: Timer?
    private var currentFileURL: URL?
    private var sessionInterrupted = false
    /// This is the record button's state. Temporary AVFoundation interruptions
    /// may close one segment, but only the button is allowed to clear this flag.
    @Published private(set) var recordingRequested = false
    private var continuationURLProvider: (() -> URL)?

    /// Called when a take ends without the user pressing stop (system
    /// interruption, backgrounding, capture error). The footage already written
    /// to disk is handed over so it is always kept.
    var onInvoluntaryFinish: ((Result<URL, Error>) -> Void)?

    enum CameraError: LocalizedError {
        case noDevice, notReady, alreadyRecording, permissionDenied, busy, noSpace

        var errorDescription: String? {
            switch self {
            case .noDevice: return "No camera available on this device."
            case .notReady: return "The camera is not running yet."
            case .alreadyRecording: return "Already recording."
            case .permissionDenied: return "Camera access is turned off. Enable it in Settings."
            case .busy: return "Saving the last take — try again in a moment."
            case .noSpace: return "Not enough free space to record. Free up storage and try again."
            }
        }
    }

    // MARK: - Lifecycle

    /// Starting the camera never fails for a format reason. The session comes up
    /// with a preset the hardware always supports, then the requested
    /// resolution / frame rate / HDR is applied as a best effort on top.
    func start(front: Bool, quality: String, fps: Int, hdr: Bool, stabilization: Bool,
               appleLog: Bool = false, logCodec: String = "prores") async throws {
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
            self?.refreshAudioInfo()
        }
        // An alarm or phone call takes the microphone for a moment. Bring the
        // capture audio session straight back instead of ending the take.
        AudioSessionManager.shared.onInterruptionEnded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.recordingRequested {
                    AudioSessionManager.shared.activateForCapture()
                }
                self.micName = AudioSessionManager.shared.currentInputName
                self.resumeRequestedRecordingIfPossible()
            }
        }
        micName = AudioSessionManager.shared.currentInputName
        refreshAudioInfo()
        usingFront = front
        status = ""

        let running: Bool = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { return continuation.resume(returning: false) }
                let ok = self.configure(front: front, quality: quality, fps: fps, hdr: hdr,
                                        stabilization: stabilization, appleLog: appleLog,
                                        logCodec: logCodec)
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
        // The format may have changed; re-lock the shutter to the new frame rate.
        setShutterAngle(shutterAngleOn)
    }

    // MARK: - 180° shutter angle

    /// True while the exposure duration is locked to half the frame duration.
    @Published private(set) var shutterAngleOn = false
    /// e.g. "1/60 s" — the shutter speed actually applied by the device.
    @Published private(set) var shutterSpeedLabel = ""
    /// Set when native HDR and custom exposure cannot coexist in the selected mode.
    @Published private(set) var shutterWarning = ""
    private var autoISOTimer: Timer?
    /// The exact half-frame exposure duration. Keep this value instead of
    /// reading the device's current duration back, because metering updates
    /// must never drift the shutter away from 180° during a take.
    private var lockedShutterDuration: CMTime?
    /// The capture mode selected by the user. Shutter control is never allowed
    /// to replace an active HDR mode with SDR.
    private var requestedHDREnabled = false

    /// 180° shutter: exposure = 1 / (2 × frame rate). Uses the documented
    /// custom exposure mode with a fixed duration; ISO is driven automatically
    /// from exposureTargetOffset, and white balance stays continuous auto.
    func setShutterAngle(_ on: Bool) {
        shutterAngleOn = on
        if on { shutterWarning = "" }
        autoISOTimer?.invalidate()
        autoISOTimer = nil
        guard let device else { shutterSpeedLabel = ""; return }
        if !on {
            lockedShutterDuration = nil
            shutterSpeedLabel = ""
            if appleLogActive, device.isExposureModeSupported(.custom) {
                // In Apple Log, iOS continuous AE holds a slow shutter and
                // under-reacts in bright light. Meter like normal video instead:
                // base ISO first, shutter shortens as light increases.
                sessionQueue.async {
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
                       (try? device.lockForConfiguration()) != nil {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                        device.unlockForConfiguration()
                    }
                }
                autoISOTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.stepLogAutoExposure() }
                }
                print("[Camera] Log auto exposure (auto shutter + ISO, base ISO priority) on")
            } else {
                sessionQueue.async { Self.applyFullAuto(on: device) }
            }
            return
        }
        guard device.isExposureModeSupported(.custom) else {
            shutterAngleOn = false
            shutterSpeedLabel = "Not supported on this camera"
            return
        }
        var frame = device.activeVideoMinFrameDuration
        if !frame.isValid || frame.seconds <= 0 { frame = CMTime(value: 1, timescale: 30) }
        let duration = CMTimeMultiplyByRatio(frame, multiplier: 1, divisor: 2)
        let denominator = Int((1 / max(duration.seconds, 0.0001)).rounded())
        lockedShutterDuration = duration
        shutterSpeedLabel = "1/\(denominator) s"
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            let format = device.activeFormat
            let iso = min(max(device.iso, format.minISO), format.maxISO)
            device.setExposureModeCustom(duration: duration, iso: iso) { [weak self, weak device] _ in
                guard let self, let device else { return }
                Task { @MainActor in self.verifyHDRAfterCustomExposure(on: device) }
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        }
        // Auto ISO: nudge ISO toward the metered target while the shutter stays fixed.
        autoISOTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepAutoISO() }
        }
    }

    /// Shutter angle off: hand shutter speed, ISO and white balance fully back
    /// to Apple's continuous automatic metering. Clears anything a custom
    /// exposure or a format change (e.g. Apple Log) may have left behind:
    /// exposure bias returns to 0 and the max exposure duration limit returns
    /// to the format default (kCMTimeInvalid), so auto shutter has its full range.
    nonisolated static func applyFullAuto(on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.activeMaxExposureDuration = .invalid
            device.exposureMode = .continuousAutoExposure
            device.setExposureTargetBias(0, completionHandler: nil)
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.unlockForConfiguration()
        print("[Camera] full auto exposure/ISO/WB applied, colorSpace=\(device.activeColorSpace.rawValue)")
    }

    /// Log exposure compensation in EV, set from the settings slider. Apple Log
    /// meters bright, so the default sits below 0 to protect highlights.
    var logExposureEV: Double = -1.0
    /// e.g. "1/2000 s · ISO 64" — what the Log auto exposure actually applied.
    @Published private(set) var logExposureLabel = ""
    /// Only touched on sessionQueue: true while a custom exposure change has
    /// not yet reached the sensor, so the next step never meters stale frames.
    nonisolated(unsafe) private var logAEPending = false

    /// Log auto exposure with the 180° shutter off. Total exposure is
    /// duration × ISO; correct it from exposureTargetOffset (EV), spending the
    /// change on shutter first while ISO stays at base, and only raising ISO
    /// once the shutter reaches the frame interval. Bright scenes therefore get
    /// fast shutter speeds (no motion blur), like normal shooting mode.
    private func stepLogAutoExposure() {
        guard !shutterAngleOn, appleLogActive, let device else { return }
        let comp = max(-3, min(1, logExposureEV))
        sessionQueue.async { [weak self] in
            guard let self, !self.logAEPending else { return }
            let offset = Double(device.exposureTargetOffset)
            guard offset.isFinite else { return }
            let format = device.activeFormat
            let minDur = format.minExposureDuration.seconds
            var frame = device.activeVideoMinFrameDuration.seconds
            if !(frame > 0) { frame = 1.0 / 30 }
            let maxDur = min(format.maxExposureDuration.seconds, frame)
            let baseISO = Double(format.minISO), maxISO = Double(format.maxISO)
            let curDur = device.exposureDuration.seconds > 0 ? device.exposureDuration.seconds : maxDur
            let curISO = Double(device.iso)
            // Error relative to the chosen Log exposure (0 = Apple's meter target).
            let error = offset - comp
            let wasCustom = device.exposureMode == .custom
            // Blown-out frames under-report how bright the scene is, so correct
            // fully (plus an extra stop when far over) instead of creeping.
            let step: Double
            if abs(error) < 0.1 { step = 0 }
            else if error > 1.5 { step = -(error + 1) }
            else if error > 0.5 { step = -error }
            else { step = -error * 0.6 }
            if step == 0 && wasCustom { return }
            let target = curDur * curISO * pow(2, step)
            var dur = min(max(target / baseISO, minDur), maxDur)
            var iso = min(max(target / dur, baseISO), maxISO)
            if !dur.isFinite || !iso.isFinite { dur = maxDur; iso = baseISO }
            guard (try? device.lockForConfiguration()) != nil else { return }
            if !wasCustom, device.exposureTargetBias != 0 {
                device.setExposureTargetBias(0, completionHandler: nil)
            }
            self.logAEPending = true
            device.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000),
                                         iso: Float(iso)) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async { self.logAEPending = false }
                let label = "1/\(Int((1 / max(dur, 0.00001)).rounded())) s · ISO \(Int(iso.rounded()))"
                Task { @MainActor in if self.logExposureLabel != label { self.logExposureLabel = label } }
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
               device.whiteBalanceMode != .continuousAutoWhiteBalance {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        }
    }

    private func stepAutoISO() {
        guard shutterAngleOn, let device, let duration = lockedShutterDuration else { return }
        sessionQueue.async {
            let offset = device.exposureTargetOffset
            let format = device.activeFormat
            // With custom exposure AVFoundation cannot auto-adjust ISO without
            // also owning shutter duration. Meter here instead: ISO follows the
            // scene, while every update reapplies the exact 180° duration.
            let targetISO = offset.isFinite ? device.iso * powf(2, -offset * 0.5) : device.iso
            let iso = min(max(targetISO, format.minISO), format.maxISO)
            let durationDrifted = CMTimeCompare(device.exposureDuration, duration) != 0
            guard durationDrifted || device.exposureMode != .custom || abs(iso - device.iso) > 0.5 else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.setExposureModeCustom(duration: duration, iso: iso) { [weak self, weak device] _ in
                guard let self, let device else { return }
                Task { @MainActor in self.verifyHDRAfterCustomExposure(on: device) }
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        }
    }

    func stop() {
        autoISOTimer?.invalidate()
        autoISOTimer = nil
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        isReady = false
        AudioSessionManager.shared.deactivate()
    }

    // MARK: - Microphone

    /// Refresh the reported sample rate, channel count and gain capability.
    func refreshAudioInfo() {
        micDetail = AudioSessionManager.shared.inputSummary
        micGainSupported = AudioSessionManager.shared.isInputGainSettable
    }

    /// Hardware input gain, 0…1. Only some microphones expose one; when they
    /// do not, the level is set on the microphone itself.
    var micGain: Double { Double(AudioSessionManager.shared.inputGain) }

    func setMicGain(_ value: Double) {
        AudioSessionManager.shared.setInputGain(Float(value))
    }

    /// Called by the prompter so metering runs only before a take.
    func setMeteringPaused(_ paused: Bool) {
        levelMonitor.isPaused = paused
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
    private func configure(front: Bool, quality: String, fps: Int, hdr: Bool, stabilization: Bool,
                           appleLog: Bool = false, logCodec: String = "prores") -> Bool {
        requestedHDREnabled = hdr && !appleLog
        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false
        // Must be false before activeColorSpace is set, or the session
        // reconfigures the device and drops Apple Log.
        // Also false for HDR so the session keeps the 10-bit HLG colour space
        // (the Camera app's Dolby Vision HDR) instead of reverting to P3.
        session.automaticallyConfiguresCaptureDeviceForWideColor = !(appleLog || hdr)


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

        // Live HEVC Log mode is only switched on below, after Log is confirmed.
        if session.outputs.contains(videoDataOutput) { session.removeOutput(videoDataOutput) }
        usesLiveHEVC = false
        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        movieOutput.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 1)

        // Metering tap. It only reads samples; the recorded file still comes
        // from the movie output exactly as before. The sink also feeds the
        // live HEVC Log writer while it is recording.
        if levelMonitor.sampleSink == nil {
            let router = sampleRouter
            levelMonitor.sampleSink = { router.appendAudio($0) }
        }
        if !session.outputs.contains(audioDataOutput), session.canAddOutput(audioDataOutput) {
            audioDataOutput.setSampleBufferDelegate(levelMonitor, queue: audioMeterQueue)
            session.addOutput(audioDataOutput)
        }

        applyMovieAudioSettings()

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
        let logOn = Self.applyFormat(on: camera, quality: quality, fps: fps, hdr: hdr, appleLog: appleLog)
        if logOn && logCodec == "hevc" {
            usesLiveHEVC = enableLiveHEVC(camera: camera, fps: fps, stabilization: stabilization)
        }
        applyRecordingCodec(appleLogActive: logOn, logCodec: logCodec)
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let spaces = camera.activeFormat.supportedColorSpaces.map { String(describing: $0.rawValue) }.joined(separator: ",")
        let fpsRanges = camera.activeFormat.videoSupportedFrameRateRanges
            .map { "\($0.minFrameRate)-\($0.maxFrameRate)" }.joined(separator: ",")
        Self.log.info("""
        camera=\(camera.localizedName, privacy: .public) position=\(camera.position.rawValue) \
        format=\(dims.width)x\(dims.height) fpsRanges=\(fpsRanges, privacy: .public) \
        supportedColorSpaces=[\(spaces, privacy: .public)] \
        activeColorSpace=\(camera.activeColorSpace.rawValue) \
        appleLogRequested=\(appleLog) appleLogActive=\(logOn) \
        codec=\(self.recordingCodecName, privacy: .public)
        """)
        appleLogActive = logOn
        appleLogDetail = logOn
            ? "Apple Log active · \(recordingCodecName)"
            : (appleLog ? Self.appleLogUnavailableReason : "")
        return true
    }

    /// A codec is only selected when the movie output itself reports it for the
    /// active format. Otherwise the existing default codec keeps recording.
    /// `logCodec` is the user's choice while Apple Log is on: "prores" or "hevc".
    /// HEVC Log bitrate in Mbps, set by the settings slider before start().
    var logHEVCMbps: Int = 40

    private func applyRecordingCodec(appleLogActive: Bool, logCodec: String) {
        if usesLiveHEVC {
            // Encoded live at exactly this rate by LogHEVCWriter.
            recordingCodecName = "HEVC \(max(10, min(200, logHEVCMbps))) Mbps"
            return
        }
        guard let connection = movieOutput.connection(with: .video) else { return }
        let available = movieOutput.availableVideoCodecTypes
        if appleLogActive, logCodec == "prores", available.contains(.proRes422) {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.proRes422], for: connection)
            recordingCodecName = "ProRes 422"
        } else if appleLogActive, logCodec == "hevc", available.contains(.hevc) {
            // User-chosen HEVC Log bitrate (slider in settings).
            let mbps = max(10, min(200, logHEVCMbps))
            movieOutput.setOutputSettings([
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: mbps * 1_000_000
                ]
            ], for: connection)
            recordingCodecName = "HEVC \(mbps) Mbps"
        } else {
            if appleLogActive, logCodec == "hevc" {
                NSLog("[Camera] HEVC not offered for this Log format (available: \(available.map { $0.rawValue }))")
            }
            movieOutput.setOutputSettings(nil, for: connection)
            if appleLogActive, logCodec == "hevc" {
                recordingCodecName = available.contains(.proRes422)
                    ? "ProRes — HEVC unavailable, files will be very large"
                    : "device default — HEVC unavailable"
            } else {
                recordingCodecName = "device default"
            }
        }
    }

    /// Switches this session to live HEVC Log recording: the camera's 10-bit
    /// frames go to LogHEVCWriter instead of the movie recorder. Returns false
    /// (and restores the movie recorder) if 10-bit frames are not offered.
    private func enableLiveHEVC(camera: AVCaptureDevice, fps: Int, stabilization: Bool) -> Bool {
        let tenBit = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        session.beginConfiguration()
        if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
        var ok = false
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            if videoDataOutput.availableVideoPixelFormatTypes.contains(tenBit) {
                videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: tenBit]
                videoDataOutput.alwaysDiscardsLateVideoFrames = false
                videoDataOutput.setSampleBufferDelegate(sampleRouter, queue: videoDataQueue)
                if let connection = videoDataOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = stabilization ? .auto : .off
                    }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                    // Pixels stay in sensor orientation; the writer stores
                    // the rotation as a track transform like the movie recorder.
                    if connection.isVideoRotationAngleSupported(0) {
                        connection.videoRotationAngle = 0
                    }
                }
                ok = true
            } else {
                NSLog("[LiveHEVC] 10-bit frames not offered: \(videoDataOutput.availableVideoPixelFormatTypes)")
                session.removeOutput(videoDataOutput)
            }
        }
        if !ok, !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            movieOutput.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
            applyMovieAudioSettings()
        }
        session.commitConfiguration()

        // Changing outputs must never drop Log or the chosen frame rate.
        if (try? camera.lockForConfiguration()) != nil {
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            camera.activeVideoMinFrameDuration = frameDuration
            camera.activeVideoMaxFrameDuration = frameDuration
            if ok, camera.activeColorSpace != .appleLog,
               camera.activeFormat.supportedColorSpaces.contains(.appleLog) {
                camera.activeColorSpace = .appleLog
            }
            camera.unlockForConfiguration()
        }
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        liveFormat = (Int(dims.width), Int(dims.height), max(1, fps))
        NSLog("[LiveHEVC] enabled=\(ok) format=\(dims.width)x\(dims.height)@\(fps) activeColorSpace=\(camera.activeColorSpace.rawValue)")
        return ok && camera.activeColorSpace == .appleLog
    }

    /// Full-rate AAC on the movie recorder: 48 kHz, every channel the
    /// microphone provides, at the top documented bitrate.
    private func applyMovieAudioSettings() {
        guard let audioConnection = movieOutput.connection(with: .audio) else { return }
        let channels = max(1, min(2, AudioSessionManager.shared.inputChannelCount))
        let rate = AudioSessionManager.shared.inputSampleRate > 0
            ? AudioSessionManager.shared.inputSampleRate
            : 48_000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 256_000 : 128_000
        ]
        movieOutput.setOutputSettings(settings, for: audioConnection)
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
    /// Returns true only when Apple Log was requested *and* really activated.
    @discardableResult
    private static func applyFormat(on camera: AVCaptureDevice, quality: String, fps: Int, hdr: Bool,
                                    appleLog: Bool = false) -> Bool {
        let target = dimensions(for: quality)
        var candidates = camera.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.width) == target.width, Int(dims.height) == target.height else { return false }
            guard format.videoSupportedFrameRateRanges.contains(where: {
                Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate
            }) else { return false }
            if hdr && !appleLog { return format.isVideoHDRSupported || supportsHLG(format) }
            return true
        }
        // Apple Log is only offered when a format for this exact resolution and
        // frame rate lists it in supportedColorSpaces.
        var wantLog = false
        if appleLog {
            let logFormats = candidates.filter { supportsAppleLogColorSpace($0) }
            if !logFormats.isEmpty {
                candidates = logFormats
                wantLog = true
            }
        }
        // HDR like the Camera app = 10-bit HLG BT.2020 (Dolby Vision). Prefer
        // those formats; fall back to classic HDR only if none exist.
        var wantHLG = false
        if hdr && !wantLog {
            let hlgFormats = candidates.filter { supportsHLG($0) }
            if !hlgFormats.isEmpty {
                candidates = hlgFormats
                wantHLG = true
            }
        }
        // Several formats can have identical dimensions and frame rates but a
        // different field of view. Choose the widest one to match the web
        // camera and avoid an apparently zoomed-in preview.
        guard let format = candidates.max(by: { $0.videoFieldOfView < $1.videoFieldOfView }) else { return false }
        guard (try? camera.lockForConfiguration()) != nil else { return false }
        camera.activeFormat = format
        camera.videoZoomFactor = max(camera.minAvailableVideoZoomFactor, 1)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        camera.activeVideoMinFrameDuration = frameDuration
        camera.activeVideoMaxFrameDuration = frameDuration
        if format.isVideoHDRSupported {
            camera.automaticallyAdjustsVideoHDREnabled = false
            // Log carries its own wide dynamic range; HDR is turned off for it.
            camera.isVideoHDREnabled = wantLog ? false : hdr
        }
        if wantHLG {
            camera.activeColorSpace = .HLG_BT2020
        } else if !wantLog && camera.activeColorSpace == .HLG_BT2020 {
            if format.supportedColorSpaces.contains(.P3_D65) { camera.activeColorSpace = .P3_D65 }
            else if format.supportedColorSpaces.contains(.sRGB) { camera.activeColorSpace = .sRGB }
        }
        if #available(iOS 17.0, *) {
            if wantLog {
                camera.activeColorSpace = .appleLog
            } else if camera.activeColorSpace == .appleLog {
                // Back to the ordinary picture when Log is switched off.
                if format.supportedColorSpaces.contains(.P3_D65) {
                    camera.activeColorSpace = .P3_D65
                } else if format.supportedColorSpaces.contains(.sRGB) {
                    camera.activeColorSpace = .sRGB
                }
            }
        }
        camera.unlockForConfiguration()
        print("[Camera] format \(target.width)x\(target.height)@\(fps) hlg=\(wantHLG) colorSpace=\(camera.activeColorSpace.rawValue) fov=\(format.videoFieldOfView)")
        if #available(iOS 17.0, *) {
            return wantLog && camera.activeColorSpace == .appleLog
        }
        return false
    }

    /// 10-bit HLG BT.2020 — the colour space of the Camera app's HDR video.
    private static func supportsHLG(_ format: AVCaptureDevice.Format) -> Bool {
        format.supportedColorSpaces.contains(.HLG_BT2020)
    }

    // MARK: - Apple Log

    static let appleLogUnavailableReason = "Apple Log unavailable for this camera/mode"

    private static func supportsAppleLogColorSpace(_ format: AVCaptureDevice.Format) -> Bool {
        guard #available(iOS 17.0, *) else { return false }
        return format.supportedColorSpaces.contains(.appleLog)
    }

    /// True only when this exact camera, resolution and frame rate reports
    /// .appleLog in its supportedColorSpaces. Never inferred from the model.
    static func appleLogAvailable(front: Bool, quality: String, fps: Int) -> Bool {
        guard let camera = pickCamera(front: front) else { return false }
        let target = dimensions(for: quality)
        return camera.formats.contains { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.width) == target.width, Int(dims.height) == target.height else { return false }
            guard format.videoSupportedFrameRateRanges.contains(where: {
                Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate
            }) else { return false }
            return supportsAppleLogColorSpace(format)
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
        let connection = activeVideoConnection
        sessionQueue.async {
            guard let connection, connection.isVideoStabilizationSupported else { return }
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
                if device.exposureMode != .custom,
                   device.isExposureModeSupported(.continuousAutoExposure) {
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

    func setContinuationURLProvider(_ provider: @escaping () -> URL) {
        continuationURLProvider = provider
    }

    func startRecording(to url: URL) throws {
        recordingRequested = true
        do {
            try startRecordingSegment(to: url, userInitiated: true)
        } catch {
            recordingRequested = false
            throw error
        }
    }

    private func startRecordingSegment(to url: URL, userInitiated: Bool) throws {
        guard session.isRunning else { throw CameraError.notReady }
        guard !outputIsWriting, !isRecording else { throw CameraError.alreadyRecording }
        // A previous take is still being closed: starting now would drop it.
        guard !isFinishing else { throw CameraError.busy }
        guard activeVideoConnection != nil else { throw CameraError.notReady }
        guard Self.hasRoomToRecord() else { throw CameraError.noSpace }

        // Reassert the fixed duration immediately before every segment. This
        // covers the first take and automatic continuation after an iOS camera
        // interruption, without changing HDR or white-balance automation.
        // In Apple Log the app's own auto exposure keeps running; handing it
        // back to iOS here would drop to a slow shutter at the start of a take.
        if shutterAngleOn { applyLockedShutterNow() }
        else if let device, !(appleLogActive && autoISOTimer != nil) { Self.applyFullAuto(on: device) }

        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw CameraError.notReady }

        let angle = Self.interfaceRotationAngle()
        if !usesLiveHEVC, let connection = movieOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        try? FileManager.default.removeItem(at: url)

        var writer: LogHEVCWriter?
        if usesLiveHEVC {
            do {
                let made = try LogHEVCWriter(
                    url: url,
                    width: liveFormat.width,
                    height: liveFormat.height,
                    fps: liveFormat.fps,
                    bitrate: max(10, min(200, logHEVCMbps)) * 1_000_000,
                    rotationAngle: angle,
                    audioChannels: AudioSessionManager.shared.inputChannelCount,
                    audioSampleRate: AudioSessionManager.shared.inputSampleRate,
                    gainDb: levelMonitor.gainDb)
                made.onFailure = { [weak self, weak made] in
                    Task { @MainActor in
                        guard let self, let made else { return }
                        self.liveWriterFailed(made)
                    }
                }
                writer = made
            } catch {
                NSLog("[LiveHEVC] could not create writer: \(error.localizedDescription)")
                throw CameraError.notReady
            }
        }

        currentFileURL = url
        isFinishing = false
        if userInitiated {
            elapsedBeforeCurrentSegment = 0
            elapsed = 0
        }
        startedAt = Date()
        if let writer {
            liveWriter = writer
            liveFileURLs.insert(url)
            sampleRouter.setWriter(writer)
        } else {
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
        isRecording = true
        AudioSessionManager.shared.isRecording = true
        levelMonitor.isPaused = true
        if userInitiated { Haptics.strong() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = self.elapsedBeforeCurrentSegment + Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func applyLockedShutterNow() {
        guard let device, let duration = lockedShutterDuration else { return }
        let format = device.activeFormat
        let iso = min(max(device.iso, format.minISO), format.maxISO)
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.setExposureModeCustom(duration: duration, iso: iso) { [weak self, weak device] _ in
            guard let self, let device else { return }
            Task { @MainActor in self.verifyHDRAfterCustomExposure(on: device) }
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.unlockForConfiguration()
    }

    /// Some camera formats cannot retain native video HDR while custom exposure
    /// is active. HDR wins in that case: immediately return exposure to Apple's
    /// automatic mode instead of silently recording reduced dynamic range.
    private func verifyHDRAfterCustomExposure(on device: AVCaptureDevice) {
        // HLG HDR lives in the colour space, not isVideoHDREnabled, and is
        // unaffected by a fixed shutter — nothing to undo there.
        guard requestedHDREnabled, shutterAngleOn, device.activeColorSpace != .HLG_BT2020,
              !device.isVideoHDREnabled else { return }
        autoISOTimer?.invalidate()
        autoISOTimer = nil
        lockedShutterDuration = nil
        shutterAngleOn = false
        shutterSpeedLabel = "Unavailable with the selected HDR mode"
        shutterWarning = "180° shutter unavailable with this HDR mode — HDR kept on"
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = true
            }
            device.unlockForConfiguration()
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        recordingRequested = false
        AudioSessionManager.shared.isRecording = false
        levelMonitor.isPaused = false
        guard outputIsWriting else {
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
        if liveWriter != nil {
            finishLiveWriter()
        } else {
            movieOutput.stopRecording()
        }

        // Safety net: if AVFoundation never calls back, keep the footage and
        // free the UI instead of leaving the app stuck in "saving".
        stopWatchdog?.invalidate()
        stopWatchdog = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let completion = self.pendingCompletion else { return }
                self.pendingCompletion = nil
                self.isFinishing = false
                self.isRecording = false
                self.liveWriter = nil
                self.sampleRouter.setWriter(nil)
                AudioSessionManager.shared.isRecording = false
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

    /// Closes the live HEVC file and reports it through the same path as the
    /// movie recorder's delegate.
    private func finishLiveWriter() {
        guard let writer = liveWriter else { return }
        liveWriter = nil
        sampleRouter.setWriter(nil)
        writer.finish { [weak self] completed, error in
            Self.logRecordedFileDiagnostics(writer.url)
            Task { @MainActor in
                self?.handleSegmentFinished(url: writer.url, error: completed ? nil : (error ?? CameraError.notReady))
            }
        }
    }

    /// The writer failed mid-take: keep everything already on disk, then the
    /// shared finish path continues in a fresh file while recording is on.
    private func liveWriterFailed(_ writer: LogHEVCWriter) {
        guard liveWriter === writer, !isFinishing else { return }
        isFinishing = true
        finishLiveWriter()
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
                self.sessionQueue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    Task { @MainActor in
                        self.isReady = self.session.isRunning
                        if self.isReady {
                            self.status = ""
                            self.resumeRequestedRecordingIfPossible()
                        }
                    }
                }
            }
        }
        center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sessionInterrupted = true
                self.status = "Camera interrupted"
                // Control Center, Notification Center and temporary system
                // overlays must not ask the movie output to stop. If iOS itself
                // ends capture, the recording delegate receives the completed
                // on-disk file and preserves it through onInvoluntaryFinish.
            }
        }
        center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sessionInterrupted = false
                self.status = ""
                self.sessionQueue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    Task { @MainActor in
                        self.isReady = self.session.isRunning
                        self.resumeRequestedRecordingIfPossible()
                    }
                }
            }
        }
    }

    private func resumeRequestedRecordingIfPossible() {
        guard recordingRequested, !sessionInterrupted, session.isRunning, !outputIsWriting,
              !isRecording, !isFinishing, let continuationURLProvider else { return }
        do {
            try startRecordingSegment(to: continuationURLProvider(), userInitiated: false)
            status = ""
        } catch CameraError.notReady, CameraError.busy {
            status = "Camera interrupted — resuming"
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.resumeRequestedRecordingIfPossible()
            }
        } catch {
            AudioSessionManager.shared.isRecording = false
            status = error.localizedDescription
        }
    }

    /// Refuses to start a take that the disk cannot hold.
    private static func hasRoomToRecord() -> Bool {
        let values = try? AppPaths.recordings.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > 300_000_000
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    /// Read-only check of a finished take: codec, measured bitrate and the
    /// colour tags actually written into the file. Never modifies the file.
    nonisolated static func logRecordedFileDiagnostics(_ url: URL) {
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let rate = try? await track.load(.estimatedDataRate),
                  let descs = try? await track.load(.formatDescriptions),
                  let desc = descs.first else {
                print("[Verify] could not read \(url.lastPathComponent)")
                return
            }
            let sub = CMFormatDescriptionGetMediaSubType(desc)
            let fourCC = String(bytes: [UInt8((sub >> 24) & 0xff), UInt8((sub >> 16) & 0xff),
                                        UInt8((sub >> 8) & 0xff), UInt8(sub & 0xff)],
                                encoding: .ascii) ?? "\(sub)"
            let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] ?? [:]
            let transfer = ext[kCVImageBufferTransferFunctionKey as String] ?? "none"
            let primaries = ext[kCVImageBufferColorPrimariesKey as String] ?? "none"
            let matrix = ext[kCVImageBufferYCbCrMatrixKey as String] ?? "none"
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            print("[Verify] \(url.lastPathComponent) codec=\(fourCC) videoBitrate=\(String(format: "%.1f", Double(rate) / 1_000_000)) Mbps fileSize=\(size / 1_000_000) MB transfer=\(transfer) primaries=\(primaries) matrix=\(matrix)")
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Self.logRecordedFileDiagnostics(outputFileURL)
        Task { @MainActor in
            self.handleSegmentFinished(url: outputFileURL, error: error)
        }
    }

    /// Shared by the movie recorder and the live HEVC Log writer.
    fileprivate func handleSegmentFinished(url outputFileURL: URL, error: Error?) {
        self.timer?.invalidate()
        self.timer = nil
        self.isRecording = false
        self.isFinishing = false
        AudioSessionManager.shared.isRecording = false
        if self.recordingRequested, let startedAt = self.startedAt {
            self.elapsedBeforeCurrentSegment += Date().timeIntervalSince(startedAt)
        }
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
        } else if !fileExists || size == 0 {
            Haptics.failure()
            result = .failure(CameraError.notReady)
        } else {
            Haptics.success()
            result = .success(outputFileURL)
        }

        if let completion = self.pendingCompletion {
            self.pendingCompletion = nil
            completion(result)
        } else {
            // Nobody asked for this stop: the system ended the take. Hand
            // the footage over so it still lands in the clip list, then
            // continue in a fresh file while the record button remains on.
            self.onInvoluntaryFinish?(result)
            self.resumeRequestedRecordingIfPossible()
        }
    }
}
