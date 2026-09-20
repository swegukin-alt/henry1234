import Foundation
import AVFoundation

/// Owns the audio session for the whole app: routing to a DJI Mic 2 / USB / AirPods
/// when present, and reporting interruptions and route changes.
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let session = AVAudioSession.sharedInstance()
    private var observing = false

    /// Re-selecting an input while AVCaptureMovieFileOutput is writing forces
    /// an audio-route renegotiation and can make AVFoundation end the file.
    var isRecording = false

    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?
    var onRouteChange: ((String) -> Void)?

    private init() {}

    func activateForCapture() {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
            )
            try session.setActive(true, options: [])
            try? session.setPreferredSampleRate(48_000)
            try? preferBestInput()
            try? preferHighestChannelCount()
        } catch {
            NSLog("[Audio] activate failed: \(error.localizedDescription)")
        }
        startObserving()
    }

    /// A USB-C interface such as the DJI Mic 2 receiver can present two
    /// channels. Ask for everything the hardware offers so nothing is folded
    /// down to mono before it reaches the file.
    func preferHighestChannelCount() throws {
        let maximum = session.maximumInputNumberOfChannels
        guard maximum > session.preferredInputNumberOfChannels else { return }
        try session.setPreferredInputNumberOfChannels(maximum)
    }

    /// Sample rate and channel count the hardware is actually delivering.
    var inputSampleRate: Double { session.sampleRate }
    var inputChannelCount: Int { session.inputNumberOfChannels }

    /// True only when iOS exposes a hardware gain control for this input.
    /// Most USB-C and wireless microphones set their own level on the device.
    var isInputGainSettable: Bool { session.isInputGainSettable }
    var inputGain: Float { session.inputGain }

    func setInputGain(_ value: Float) {
        guard session.isInputGainSettable else { return }
        try? session.setInputGain(min(1, max(0, value)))
    }

    /// Short, human readable connection summary: "USB-C · 48 kHz · 2 ch".
    var inputSummary: String {
        let port = session.currentRoute.inputs.first?.portType
        let kind: String
        switch port {
        case .some(.usbAudio): kind = "USB-C"
        case .some(.headsetMic): kind = "Wired"
        case .some(.bluetoothHFP): kind = "Bluetooth"
        case .some(.builtInMic): kind = "Built-in"
        default: kind = "Mic"
        }
        let rate = String(format: "%.0f kHz", session.sampleRate / 1000)
        return "\(kind) · \(rate) · \(session.inputNumberOfChannels) ch"
    }

    func activateForPlayback() {
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true, options: [])
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    var availableInputs: [AVAudioSessionPortDescription] {
        session.availableInputs ?? []
    }

    var currentInputName: String {
        session.currentRoute.inputs.first?.portName ?? "No microphone"
    }

    /// External wins over built-in: USB (DJI Mic 2 receiver), then wired, then
    /// Bluetooth, then the phone's own mic.
    func preferBestInput() throws {
        let inputs = availableInputs
        let ranked: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .bluetoothHFP, .builtInMic]
        for port in ranked {
            if let match = inputs.first(where: { $0.portType == port }) {
                try session.setPreferredInput(match)
                return
            }
        }
    }

    func select(input: AVAudioSessionPortDescription) {
        try? session.setPreferredInput(input)
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self?.onInterruptionBegan?()
            } else {
                try? self?.session.setActive(true)
                self?.onInterruptionEnded?()
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = rawReason.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            let physicalInputChanged = reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
            if physicalInputChanged, !self.isRecording {
                try? self.preferBestInput()
            }
            self.onRouteChange?(self.currentInputName)
        }
    }
}
