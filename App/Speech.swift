import Foundation
import AVFoundation
import MediaPlayer
import NaturalLanguage

/// Reads an article aloud: natural online voices (Edge) by default, the system voice as fallback.
/// Works in the background and from the lock screen.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = Speaker()
    @Published private(set) var item: FeedItem?
    @Published private(set) var isSpeaking = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var loading = false
    private let synth = AVSpeechSynthesizer()
    private var length = 1
    private var offset = 0
    private var fullText = ""
    private var edgeTask: Task<Void, Never>?
    private var audio: AVAudioPlayer?
    private var finished: CheckedContinuation<Void, Never>?
    private var previewPlayer: AVAudioPlayer?

    private override init() {
        super.init()
        synth.delegate = self
    }

    var isActive: Bool { item != nil }

    static var rate: Float {
        let r = UserDefaults.standard.double(forKey: "speechRate")
        return r == 0 ? AVSpeechUtteranceDefaultSpeechRate : Float(r)
    }
    /// speechRate 0.42 / 0.5 / 0.56 → -20% / 0% / +20% for the online voice.
    static var edgeRate: Int { Int(((Double(rate) - 0.5) / 0.06 * 20).rounded()) }
    static var edgePitch: Int { UserDefaults.standard.integer(forKey: "edgePitch") }
    static var useEdge: Bool { (UserDefaults.standard.string(forKey: "speechEngine") ?? "edge") == "edge" }
    static var edgeVoice: String { UserDefaults.standard.string(forKey: "edgeVoice") ?? EdgeTTS.defaultVoice }

    private func prepareSession() {
        if Player.shared.isPlaying { Player.shared.pause() }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func speak(_ item: FeedItem, text: String) {
        stopPlayback()
        prepareSession()
        self.item = item
        fullText = text
        progress = 0
        isSpeaking = true
        if Self.useEdge {
            let lang = Self.voiceLanguage(for: text)
            let voice = EdgeTTS.voice(for: lang, chosen: Self.edgeVoice)
            let parts = EdgeTTS.chunks(text)
            edgeTask = Task { [weak self] in await self?.runEdge(parts, voice: voice) }
        } else {
            speakSystem(text, from: 0)
        }
        updateNowPlaying()
    }

    private func speakSystem(_ text: String, from start: Int) {
        let u = AVSpeechUtterance(string: text)
        let lang = Self.voiceLanguage(for: text)
        if lang.hasPrefix("zh"), let id = UserDefaults.standard.string(forKey: "systemVoice"),
           let v = AVSpeechSynthesisVoice(identifier: id), v.language.hasPrefix(String(lang.prefix(2))) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: lang)
        }
        u.rate = Self.rate
        offset = start
        length = max(1, (fullText as NSString).length)
        synth.speak(u)
    }

    private func runEdge(_ parts: [String], voice: String) async {
        let rate = Self.edgeRate, pitch = Self.edgePitch
        func fetch(_ i: Int) -> Task<Data, Error> {
            Task { try await EdgeTTS.synthesize(parts[i], voice: voice, rate: rate, pitch: pitch) }
        }
        var next: Task<Data, Error>? = parts.isEmpty ? nil : fetch(0)
        var i = 0
        while let cur = next {
            loading = audio == nil || !(audio?.isPlaying ?? false)
            let data: Data
            do { data = try await cur.value } catch {
                loading = false
                if Task.isCancelled || item == nil { return }
                // Online voice unreachable: carry on with the system voice from here.
                let rest = parts[i...].joined(separator: "\n")
                let done = parts[..<i].joined(separator: "\n")
                speakSystem(rest, from: (done as NSString).length)
                return
            }
            if Task.isCancelled || item == nil { return }
            next = i + 1 < parts.count ? fetch(i + 1) : nil
            loading = false
            if let p = try? AVAudioPlayer(data: data) {
                p.delegate = self
                p.prepareToPlay()
                audio = p
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    finished = c
                    if isSpeaking { p.play() }
                }
            }
            if Task.isCancelled || item == nil { next?.cancel(); return }
            i += 1
            progress = min(1, Double(i) / Double(max(1, parts.count)))
        }
        audio = nil
        finish()
    }

    /// Plays a short sample of the chosen online voice.
    func preview(voice: String) async -> Bool {
        let sample = "你好，我是\(EdgeTTS.voices.first { $0.id == voice }?.name ?? "")。这是 Hark 推送的朗读声音。"
        do {
            let d = try await EdgeTTS.synthesize(sample, voice: voice, rate: Self.edgeRate, pitch: Self.edgePitch)
            prepareSession()
            previewPlayer = try AVAudioPlayer(data: d)
            previewPlayer?.play()
            return true
        } catch { return false }
    }

    func toggle() { isSpeaking ? pause() : resume() }
    func pause() {
        if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
        audio?.pause()
        isSpeaking = false
        updateNowPlaying()
    }
    func resume() {
        guard item != nil else { return }
        if synth.isPaused { synth.continueSpeaking() }
        if let a = audio, !a.isPlaying { a.play() }
        isSpeaking = true
        updateNowPlaying()
    }
    func stop() {
        stopPlayback()
        finish()
    }
    private func stopPlayback() {
        edgeTask?.cancel()
        edgeTask = nil
        audio?.stop()
        audio = nil
        if let c = finished { finished = nil; c.resume() }
        synth.stopSpeaking(at: .immediate)
        loading = false
    }
    private func finish() {
        item = nil
        isSpeaking = false
        progress = 0
        loading = false
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

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if let c = self.finished { self.finished = nil; c.resume() }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            if let c = self.finished { self.finished = nil; c.resume() }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let loc = characterRange.location
        Task { @MainActor in self.progress = min(1, Double(self.offset + loc) / Double(self.length)) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
