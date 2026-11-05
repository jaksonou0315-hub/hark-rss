import Foundation
import AVFoundation
import MediaPlayer
import NaturalLanguage

/// Reads an article aloud with the system voice. Works in the background and from the lock screen.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    @Published private(set) var item: FeedItem?
    @Published private(set) var isSpeaking = false
    @Published private(set) var progress: Double = 0
    private let synth = AVSpeechSynthesizer()
    private var length = 1

    private override init() {
        super.init()
        synth.delegate = self
    }

    var isActive: Bool { item != nil }

    static var rate: Float {
        let r = UserDefaults.standard.double(forKey: "speechRate")
        return r == 0 ? AVSpeechUtteranceDefaultSpeechRate : Float(r)
    }

    func speak(_ item: FeedItem, text: String) {
        synth.stopSpeaking(at: .immediate)
        if Player.shared.isPlaying { Player.shared.pause() }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Self.voiceLanguage(for: text))
        u.rate = Self.rate
        length = max(1, (text as NSString).length)
        self.item = item
        progress = 0
        isSpeaking = true
        synth.speak(u)
        updateNowPlaying()
    }
    func toggle() { isSpeaking ? pause() : resume() }
    func pause() {
        if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
        isSpeaking = false
        updateNowPlaying()
    }
    func resume() {
        guard item != nil else { return }
        if synth.isPaused { synth.continueSpeaking() }
        isSpeaking = true
        updateNowPlaying()
    }
    func stop() {
        synth.stopSpeaking(at: .immediate)
        finish()
    }
    private func finish() {
        item = nil
        isSpeaking = false
        progress = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    static func voiceLanguage(for text: String) -> String {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(1200)))
        guard let l = r.dominantLanguage else { return "zh-CN" }
        if l == .simplifiedChinese { return "zh-CN" }
        if l == .traditionalChinese { return "zh-TW" }
        if l == .english { return "en-US" }
        if l == .japanese { return "ja-JP" }
        if l == .korean { return "ko-KR" }
        return l.rawValue
    }

    private func updateNowPlaying() {
        guard let i = item else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: i.title,
            MPMediaItemPropertyArtist: "朗读 · " + i.source,
            MPNowPlayingInfoPropertyPlaybackRate: isSpeaking ? 1.0 : 0.0,
        ]
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let loc = characterRange.location
        Task { @MainActor in self.progress = min(1, Double(loc) / Double(self.length)) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
