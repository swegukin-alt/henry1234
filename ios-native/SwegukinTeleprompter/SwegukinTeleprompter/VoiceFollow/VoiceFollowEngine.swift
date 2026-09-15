import Foundation
import Speech
import AVFoundation

/// Native voice follow: Apple's on-device recogniser listening through
/// AVAudioEngine. Recognition is kept apart from the matching logic so the
/// teleprompter only ever receives a word index.
@MainActor
final class VoiceFollowEngine: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var matchedIndex: Int?
    @Published private(set) var status: String = ""

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var scriptWords: [String] = []
    private var cursor = 0

    func start(script: String, locale: Locale = Locale.current) async {
        guard !isListening else { return }
        guard await PermissionManager.requestSpeech(), await PermissionManager.requestMicrophone() else {
            status = "Voice follow needs microphone and speech access."
            return
        }
        scriptWords = ScriptText.words(in: script).map(Self.normalise)
        cursor = 0

        let koreanish = script.unicodeScalars.contains { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }
        let preferred = koreanish ? Locale(identifier: "ko-KR") : locale
        recognizer = SFSpeechRecognizer(locale: preferred) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            status = "Speech recognition is unavailable for this language."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = false
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            status = "Could not start listening: \(error.localizedDescription)"
            return
        }
        isListening = true
        status = ""

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                Task { @MainActor in self.consume(spoken: spoken) }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.restartIfNeeded(script: self.scriptWords.joined(separator: " ")) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false
        matchedIndex = nil
    }

    /// Matches the tail of what was heard against the next words in the script,
    /// only ever moving forward so a repeated word cannot drag the text back.
    private func consume(spoken: String) {
        let heard = ScriptText.words(in: spoken).map(Self.normalise)
        guard let last = heard.last, !last.isEmpty else { return }
        let window = 24
        let upper = min(scriptWords.count, cursor + window)
        guard cursor < upper else { return }
        for index in cursor..<upper where scriptWords[index].hasPrefix(last) || last.hasPrefix(scriptWords[index]) {
            cursor = index
            matchedIndex = index
            return
        }
    }

    private func restartIfNeeded(script: String) {
        guard isListening else { return }
        stop()
        Task { await start(script: script) }
    }

    private static func normalise(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
