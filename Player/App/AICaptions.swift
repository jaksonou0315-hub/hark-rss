import Foundation
import SwiftUI
import AVFoundation
import Speech
import ReplayKit
import Translation

// MARK: - Apple Translation bridge (system translation, on-device language packs)

/// Hosts one TranslationSession for the player screen. Work is queued as closures and run inside `.translationTask`.
@MainActor
final class TranslationBridge: ObservableObject {
    @Published var config: TranslationSession.Configuration?
    private var sink: AsyncStream<Job>.Continuation?
    private var serveToken = 0

    struct Job { let run: (TranslationSession) async -> Void }

    var targetId: String { AppSettings.shared.translateTarget }

    private func ensureConfig() {
        let target = Locale.Language(identifier: targetId)
        if config?.target != target || config == nil {
            config = TranslationSession.Configuration(source: nil, target: target)
        } else if sink == nil {
            config?.invalidate()
        }
    }

    /// Called from the view's translationTask closure.
    func serve(_ session: TranslationSession) async {
        let (stream, cont) = AsyncStream<Job>.makeStream()
        serveToken += 1
        let token = serveToken
        sink = cont
        for await job in stream { await job.run(session) }
        if serveToken == token { sink = nil }
    }

    func perform<T>(_ work: @escaping (TranslationSession) async -> T?) async -> T? {
        ensureConfig()
        for _ in 0..<100 where sink == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard let sink else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let job = Job { s in c.resume(returning: await work(s)) }
            if case .terminated = sink.yield(job) { c.resume(returning: nil) }
        }
    }

    func translate(_ text: String) async -> String? {
        let t = text.trimmed
        guard !t.isEmpty else { return nil }
        return await perform { s in try? await s.translate(t).targetText }
    }

    func translateBatch(_ texts: [String]) async -> [String]? {
        await perform { s -> [String]? in
            let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            guard let rs = try? await s.translations(from: reqs) else { return nil }
            var out = texts
            for r in rs { if let i = Int(r.clientIdentifier ?? ""), i < out.count { out[i] = r.targetText } }
            return out
        }
    }
}

struct TranslationHost: ViewModifier {
    @ObservedObject var bridge: TranslationBridge
    func body(content: Content) -> some View {
        content.translationTask(bridge.config) { session in
            await bridge.serve(session)
        }
    }
}

// MARK: - Subtitle file translation (srt / vtt / ass → translated srt)

enum SubtitleTranslator {
    struct Cue { var start: String; var end: String; var text: String }

    static func parse(_ raw: String, ext: String) -> [Cue] {
        let s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if ext == "ass" || ext == "ssa" { return parseASS(s) }
        var cues: [Cue] = []
        for block in s.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let fix: (String) -> String = { t in
                var x = t.trimmed.components(separatedBy: " ").first ?? ""
                x = x.replacingOccurrences(of: ".", with: ",")
                if x.filter({ $0 == ":" }).count == 1 { x = "00:" + x }
                return x
            }
            let text = lines[(ti + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !text.trimmed.isEmpty { cues.append(Cue(start: fix(parts[0]), end: fix(parts[1]), text: text)) }
        }
        return cues
    }

    private static func parseASS(_ s: String) -> [Cue] {
        var fields: [String] = []
        var cues: [Cue] = []
        for line in s.components(separatedBy: "\n") {
            let l = line.trimmed
            if l.hasPrefix("Format:"), fields.isEmpty || l.lowercased().contains("text") {
                fields = l.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if l.hasPrefix("Dialogue:"), !fields.isEmpty {
                let body = String(l.dropFirst(9))
                let parts = body.split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == fields.count, let si = fields.firstIndex(of: "start"), let ei = fields.firstIndex(of: "end"),
                      let ti = fields.firstIndex(of: "text") else { continue }
                let text = parts[ti].replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
                if text.trimmed.isEmpty { continue }
                cues.append(Cue(start: assTime(parts[si]), end: assTime(parts[ei]), text: text))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func assTime(_ t: String) -> String {
        // h:mm:ss.cc → hh:mm:ss,mmm
        let p = t.trimmed.split(separator: ":")
        guard p.count == 3 else { return "00:00:00,000" }
        let sec = p[2].split(separator: ".")
        let h = Int(p[0]) ?? 0, m = Int(p[1]) ?? 0, s = Int(sec.first ?? "0") ?? 0
        let cs = sec.count > 1 ? (Int(sec[1]) ?? 0) * (sec[1].count == 2 ? 10 : 1) : 0
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, cs)
    }

    static func translateFile(_ url: URL, bridge: TranslationBridge, bilingual: Bool) async throws -> URL {
        let data = try Data(contentsOf: url)
        guard let raw = SubtitleService.decode(data) else { throw AppError.message("无法读取字幕文件") }
        let cues = parse(raw, ext: url.pathExtension.lowercased())
        guard !cues.isEmpty else { throw AppError.message("字幕里没有可翻译的文本（图形字幕不支持翻译）") }
        var translated: [String] = []
        let chunk = 200
        var i = 0
        while i < cues.count {
            let part = cues[i..<min(i + chunk, cues.count)].map { $0.text.replacingOccurrences(of: "\n", with: " ") }
            guard let t = await bridge.translateBatch(part) else {
                throw AppError.message("系统翻译不可用：请在「设置 › App › 翻译」下载对应语言，或检查目标语言设置")
            }
            translated += t
            i += chunk
        }
        var out = ""
        for (n, c) in cues.enumerated() {
            let t = n < translated.count ? translated[n] : c.text
            out += "\(n + 1)\n\(c.start) --> \(c.end)\n\(t)\n"
            if bilingual { out += c.text.replacingOccurrences(of: "\n", with: " ") + "\n" }
            out += "\n"
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("translated-\(UUID().uuidString.prefix(8)).srt")
        try out.data(using: .utf8)!.write(to: dst)
        return dst
    }
}

// MARK: - AI live subtitles: app audio (ReplayKit in-app capture) → on-device speech recognition → optional translation

/// Thread-safe audio pipe from ReplayKit's capture queue into the current recognition request.
final class SpeechAudioPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private(set) var lastLevel: Float = 0

    func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }

    func feed(_ sb: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        var asbd = asbdPtr.pointee
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr else { return }

        lock.lock(); defer { lock.unlock() }
        guard let request else { return }
        if converter == nil || inFormat != fmt {
            converter = AVAudioConverter(from: fmt, to: outFormat)
            inFormat = fmt
        }
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(frames) * outFormat.sampleRate / max(fmt.sampleRate, 1)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        if out.frameLength > 0 {
            if let ch = out.floatChannelData?[0] {
                var peak: Float = 0
                for i in 0..<Int(out.frameLength) { peak = max(peak, abs(ch[i])) }
                lastLevel = peak
            }
            request.append(out)
        }
    }
}

@MainActor
final class LiveCaptioner: ObservableObject {
    @Published var running = false
    @Published var original = ""
    @Published var translated = ""
    @Published var status: String?

    var bridge: TranslationBridge?
    private let pipe = SpeechAudioPipe()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var currentFull = ""
    private var lastChange = Date()
    private var requestStarted = Date()
    private var watchdog: Timer?
    private var clearTask: Task<Void, Never>?

    func start() async {
        guard !running else { return }
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else { status = "请在「设置 › 隐私与安全性 › 语音识别」允许 Hark 影音"; return }
        let lang = AppSettings.shared.aiSpeechLocale
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: lang)), r.isAvailable else {
            status = "这台 iPhone 不支持该语言的语音识别"; return
        }
        recognizer = r
        newRequest()
        let rec = RPScreenRecorder.shared()
        rec.isMicrophoneEnabled = false
        let pipe = self.pipe
        do {
            try await rec.startCapture(handler: { sb, type, err in
                guard err == nil, type == .audioApp else { return }
                pipe.feed(sb)
            })
        } catch {
            status = "需要允许「录制屏幕」才能识别影片声音（只在本机处理，不会保存）"
            stopRecognition()
            return
        }
        running = true
        status = r.supportsOnDeviceRecognition ? "AI 字幕已开启（本机识别）" : "AI 字幕已开启"
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRotate() }
        }
    }

    func stop() {
        guard running || task != nil else { return }
        running = false
        watchdog?.invalidate(); watchdog = nil
        if RPScreenRecorder.shared().isRecording { RPScreenRecorder.shared().stopCapture { _ in } }
        stopRecognition()
        original = ""; translated = ""
    }

    private func stopRecognition() {
        pipe.setRequest(nil)
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
    }

    private func newRequest() {
        guard let recognizer else { return }
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        req.taskHint = .dictation
        let old = request
        request = req
        pipe.setRequest(req)
        old?.endAudio()
        requestStarted = Date()
        lastChange = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let final = result.isFinal
            Task { @MainActor in self?.handle(text: text, final: final, gen: gen) }
        }
    }

    private func handle(text: String, final: Bool, gen: Int) {
        guard gen == generation else { return }
        if text != currentFull { currentFull = text; original = Self.tail(text); lastChange = Date() }
        clearTask?.cancel()
        if final { commit(text) }
    }

    /// Rotate the request on a pause (one subtitle line per utterance) or every 45 s.
    private func checkRotate() {
        guard running else { return }
        let idle = Date().timeIntervalSince(lastChange)
        let age = Date().timeIntervalSince(requestStarted)
        if (!currentFull.isEmpty && idle > 0.9) || age > 45 {
            let pending = currentFull
            currentFull = ""
            newRequest()
            if !pending.isEmpty { commit(pending, fromRotate: true) }
        }
    }

    private var lastCommitted = ""
    private func commit(_ text: String, fromRotate: Bool = false) {
        let t = text.trimmed
        guard !t.isEmpty, t != lastCommitted else { return }
        lastCommitted = t
        let shown = Self.tail(t)
        original = shown
        if AppSettings.shared.aiTranslate, let bridge {
            Task {
                if let tr = await bridge.translate(t), self.lastCommitted == t { self.translated = Self.tail(tr) }
            }
        }
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled, self.original == shown { self.original = ""; self.translated = "" }
        }
    }

    static func tail(_ s: String, max: Int = 70) -> String {
        guard s.count > max else { return s }
        let cut = s.suffix(max)
        if let sp = cut.firstIndex(where: { $0 == " " || $0 == "，" || $0 == "," || $0 == "。" }) { return String(cut[cut.index(after: sp)...]) }
        return String(cut)
    }
}

struct LiveCaptionOverlay: View {
    @ObservedObject var captioner: LiveCaptioner
    @ObservedObject private var style = SubtitleStyle.shared
    private func f(_ size: Double, _ w: Font.Weight) -> Font {
        let sz = size * style.scale / 100
        let wt: Font.Weight = style.bold ? .bold : w
        return style.font.isEmpty ? .system(size: sz, weight: wt) : .custom(style.font, size: sz).weight(wt)
    }
    var body: some View {
        VStack {
            Spacer()
            if captioner.running, !(captioner.original.isEmpty && captioner.translated.isEmpty) {
                VStack(spacing: 4) {
                    if AppSettings.shared.aiTranslate, !captioner.translated.isEmpty {
                        Text(captioner.translated).font(f(19, .semibold))
                    }
                    if AppSettings.shared.aiShowOriginal || !AppSettings.shared.aiTranslate || captioner.translated.isEmpty {
                        Text(captioner.original).font(f(AppSettings.shared.aiTranslate ? 14 : 19, .medium))
                            .opacity(AppSettings.shared.aiTranslate ? 0.85 : 1)
                    }
                }
                .foregroundStyle(style.swiftUIColor)
                .shadow(color: .black.opacity(style.outline == 0 ? 0 : 1), radius: 2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(style.background ? style.backgroundOpacity : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: captioner.original)
    }
}

enum AILanguages {
    static let speech: [(String, String)] = [("en-US", "英语"), ("ja-JP", "日语"), ("ko-KR", "韩语"), ("zh-CN", "普通话"),
                                             ("zh-HK", "粤语"), ("zh-TW", "台湾国语"), ("fr-FR", "法语"), ("de-DE", "德语"),
                                             ("es-ES", "西班牙语"), ("it-IT", "意大利语"), ("ru-RU", "俄语"), ("pt-BR", "葡萄牙语")]
    static let targets: [(String, String)] = [("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어")]
}
