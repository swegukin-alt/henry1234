import Foundation
import AVFoundation

/// Owns the audio session for the whole app: routing to a DJI Mic 2 / USB / AirPods
/// when present, and reporting interruptions and route changes.
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let session = AVAudioSession.sharedInstance()
    private var observing = false

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
        } catch {
            NSLog("[Audio] activate failed: \(error.localizedDescription)")
        }
        startObserving()
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
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            try? self.preferBestInput()
            self.onRouteChange?(self.currentInputName)
        }
    }
}
