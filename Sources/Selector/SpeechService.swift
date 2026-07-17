import AVFoundation
import Foundation

final class SpeechService: NSObject {
    private let provider: SpeechProvider
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var currentTask: CancellableRequest?

    /// Called whenever speaking state flips. Always delivered on the main queue.
    var onStateChange: ((Bool) -> Void)?

    private(set) var isSpeaking: Bool = false {
        didSet {
            guard oldValue != isSpeaking else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStateChange?(self.isSpeaking)
            }
        }
    }

    init(provider: SpeechProvider) {
        self.provider = provider
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if provider.hasAPIKey {
            speakViaProvider(trimmed)
        } else {
            speakViaSystem(trimmed)
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    private func speakViaProvider(_ text: String) {
        isSpeaking = true
        Logger.log("TTS provider begin (\(text.count) chars, voice=\(provider.ttsVoiceName))")
        currentTask = provider.synthesizeSpeech(text: text) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.currentTask = nil
                switch result {
                case .success(let data):
                    self.playAudio(data)
                case .failure(.cancelled):
                    self.isSpeaking = false
                case .failure(let err):
                    Logger.log("TTS provider failed (\(err.localizedDescription)); falling back to system voice")
                    self.speakViaSystem(text)
                }
            }
        }
    }

    private func playAudio(_ data: Data) {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            if !p.play() {
                Logger.log("AVAudioPlayer.play() returned false; falling back to system voice")
                player = nil
                speakViaSystem("Playback failed.")
            } else {
                Logger.log("TTS provider playing (\(data.count) bytes)")
            }
        } catch {
            Logger.log("AVAudioPlayer init failed: \(error.localizedDescription); falling back to system voice")
            isSpeaking = false
        }
    }

    private func speakViaSystem(_ text: String) {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        Logger.log("TTS system fallback (\(text.count) chars)")
        synth.speak(utt)
    }
}

extension SpeechService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        isSpeaking = false
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Logger.log("AVAudioPlayer decode error: \(error?.localizedDescription ?? "unknown")")
        self.player = nil
        isSpeaking = false
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
}
