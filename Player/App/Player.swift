import Foundation
import SwiftUI
import UIKit
import AVFoundation
import VLCKitSPM
import Combine

@MainActor
final class PlaybackRouter: ObservableObject {
    static let shared = PlaybackRouter()
    @Published var request: PlayRequest?
    /// Show the player without the slide-up; its onAppear snaps to landscape while animations are off,
    /// so playback starts straight in full screen.
    func play(_ r: PlayRequest) {
        guard request == nil else { request = r; return }
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        if phone { UIView.setAnimationsEnabled(false) }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { request = r }
        if phone { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { UIView.setAnimationsEnabled(true) } }
    }
}

struct TrackInfo: Identifiable, Hashable { var id: Int32; var name: String }

@MainActor
final class PlayerController: NSObject, ObservableObject {
    let engine: MediaEngine
    private var styleSub: AnyCancellable?
    @Published var badges: [String] = []
    @Published var mediaBadges: [String] = []   // stays; shown top-centre with the controls
    let pipBox = SamplePiP()
    @Published var pipActive = false
    private var didBadge = false
    let request: PlayRequest
    var videoView: UIView { engine.view }

    @Published var title: String
    @Published var isPlaying = false
    @Published var buffering = true
    @Published var position: Float = 0
    @Published var timeMs: Int32 = 0
    @Published var lengthMs: Int32 = 0
    @Published var subtitleTracks: [TrackInfo] = []
    @Published var audioTracks: [TrackInfo] = []
    @Published var currentSub: Int32 = -1
    @Published var currentAudio: Int32 = -1
    @Published var rate: Float = 1
    @Published var subDelayMs = 0
    @Published var errorText: String?
    @Published var toast: String?
    @Published var ended = false
    @Published var loadedSubs: [(name: String, url: URL)] = []
    @Published var translating = false
    let bridge = TranslationBridge()
    let captioner = LiveCaptioner()

    private var timer: Timer?
    private var playable: PlayableMedia?
    private var pendingSubs: [URL] = []
    private var didResume = false
    private var didPickTrack = false
    private var didAutoOnline = false
    private var startedAt = Date()

    // intro / credits
    @Published var segments = SkipSegments()
    @Published var activeSkip: (label: String, to: Int32?)? = nil   // shown as 「跳过片头」 pill; to nil = end
    private var skipped = Set<String>()
    private var segFetched = false
    private(set) lazy var nextRequest: PlayRequest? = Self.findNext(request)
    var onNext: ((PlayRequest) -> Void)?

    /// Series / film key used for manual intro / credits marks.
    var segKey: String {
        if let i = request.itemId { return i }
        return (request.file.path as NSString).deletingLastPathComponent
    }

    init(_ r: PlayRequest) {
        request = r
        title = r.title ?? (r.file.name as NSString).deletingPathExtension
        let localCopy = DownloadStore.shared.localURL(r.source.id.uuidString + ":" + r.file.id) != nil
        engine = EngineChooser.useMPV(r, local: localCopy) ? MPVEngine() : VLCEngine()
        super.init()
        captioner.bridge = bridge
        styleSub = SubtitleStyle.shared.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applySubtitleStyleLive() }
    }

    func applySubtitleStyleLive() { engine.applySubtitleStyle() }

    func start() async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let provider = SourceStore.shared.provider(for: request.source)
        do {
            let p = try await DownloadStore.shared.playable(provider, request.file)
            playable = p
            engine.open(p)
            let dr = Float(PlayerPrefs.defaultRate)
            if abs(dr - 1) > 0.01 { engine.setRate(dr); rate = dr }
            startedAt = Date()
            startTimer()
            // sidecar subtitles: server-provided URLs + files next to the video (downloaded and re-encoded to UTF-8)
            var subs: [URL] = []
            for u in p.subtitleFiles {
                if let r = try? await HTTP.data(URLRequest(url: u)), let f = try? SubtitleService.saveTemp(r.0, name: u.lastPathComponent) { subs.append(f); loadedSubs.append((u.lastPathComponent, f)) }
            }
            if AppSettings.shared.autoSidecar {
                let side = request.extraSubtitles + SubtitleService.sidecars(for: request.file, in: request.siblings)
                var seen = Set<String>()
                for s in side where seen.insert(s.id).inserted {
                    if let d = try? await provider.fetchData(s), let f = try? SubtitleService.saveTemp(d, name: s.name) { subs.append(f); loadedSubs.append((s.name, f)) }
                }
            }
            pendingSubs = subs
        } catch {
            errorText = error.localizedDescription
            buffering = false
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let st = engine.state
        let playing = engine.isPlaying
        if isPlaying != playing { isPlaying = playing }
        let buf = (st == .opening || st == .buffering) && !playing
        if buf != buffering { buffering = buf }
        let nt = engine.timeMs
        if nt != timeMs { timeMs = nt }
        let nl = engine.lengthMs
        if nl != lengthMs { lengthMs = nl }
        if lengthMs > 0 { let p = engine.position; if p != position { position = p } }
        if st == .error, errorText == nil {
            errorText = (engine as? MPVEngine)?.errorText ?? "无法播放此文件（网络错误或格式不受支持）"
            buffering = false
        }
        if st == .ended, !ended {
            ended = true
            if let k = playable?.resumeKey { Resume.clear(k) }
            if PlayerPrefs.autoNext, let n = nextRequest, let f = onNext { f(n); return }
        }
        guard playing else { return }
        if !segFetched, lengthMs > 0 { segFetched = true; Task { await loadSegments() } }
        checkSkips()
        if engine is MPVEngine, timeMs > 3000 { MPVGuard.clear() }

        if !pendingSubs.isEmpty {
            let subs = pendingSubs
            pendingSubs = []
            for (i, u) in subs.enumerated() {
                engine.addSubtitle(u, select: i == 0)
            }
            didPickTrack = true
            toast = "已加载 \(subs.count) 个外挂字幕"
        }
        if !didResume, AppSettings.shared.resumePlayback, let k = playable?.resumeKey {
            didResume = true
            let ms = Resume.get(k)
            if ms > 10_000, lengthMs == 0 || ms < lengthMs - 15_000 {
                engine.seek(ms: ms)
                toast = "已从 \(Self.fmt(ms)) 继续播放"
            }
        } else if let k = playable?.resumeKey, timeMs > 0, Int(timeMs) % 5000 < 450 {
            Resume.set(k, timeMs, total: lengthMs)
        }
        refreshTracks()
        if !didBadge, Date().timeIntervalSince(startedAt) > 1.0 { didBadge = true; computeBadges() }
        if !didPickTrack, Date().timeIntervalSince(startedAt) > 1.5 {
            didPickTrack = true
            if let t = subtitleTracks.first(where: { $0.id >= 0 && SubtitleService.trackMatchesPreferred($0.name) }) {
                selectSub(t.id)
            } else if AppSettings.shared.autoOnlineSubtitle, SubtitleService.hasOnlineProvider, !didAutoOnline,
                      !subtitleTracks.contains(where: { $0.id >= 0 }) {
                didAutoOnline = true
                Task { await autoOnline() }
            }
        }
    }

    // MARK: next episode

    static func findNext(_ r: PlayRequest) -> PlayRequest? {
        if let iid = r.itemId, let fid = r.fileId,
           let item = LibraryStore.shared.items.first(where: { $0.id == iid }), item.isTV {
            let curSeason = item.files.first(where: { $0.id == r.fileId })?.season
            let eps = item.files.filter { $0.episode != nil && (curSeason == nil || $0.season == curSeason) }
                .sorted { ($0.season ?? 0, $0.episode ?? 0, $0.file.name) < ($1.season ?? 0, $1.episode ?? 0, $1.file.name) }
            guard let i = eps.firstIndex(where: { $0.id == fid }), i + 1 < eps.count else { return nil }
            let f = eps[i + 1]
            guard let src = SourceStore.shared.source(f.sourceId) else { return nil }
            return PlayRequest(source: src, file: f.file, siblings: [], title: "\(item.title) 第\(f.episode ?? 0)集",
                               extraSubtitles: f.subtitles, itemId: iid, fileId: f.id)
        }
        let vids = r.siblings.filter { $0.isVideo }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let i = vids.firstIndex(where: { $0.id == r.file.id }), i + 1 < vids.count else { return nil }
        return PlayRequest(source: r.source, file: vids[i + 1], siblings: r.siblings)
    }

    struct EpisodeEntry: Identifiable { let id: String; let title: String; let subtitle: String; let still: URL?; let current: Bool; let request: PlayRequest }

    /// Every episode of this show (library) or every video in the folder, for the playlist strip.
    lazy var episodes: [EpisodeEntry] = {
        let r = request
        if let iid = r.itemId, let item = LibraryStore.shared.items.first(where: { $0.id == iid }), item.isTV {
            let eps = item.files.filter { $0.episode != nil }
                .sorted { ($0.season ?? 0, $0.episode ?? 0, $0.file.name) < ($1.season ?? 0, $1.episode ?? 0, $1.file.name) }
            return eps.compactMap { f in
                guard let src = SourceStore.shared.source(f.sourceId) else { return nil }
                let req = PlayRequest(source: src, file: f.file, siblings: [], title: "\(item.title) 第\(f.episode ?? 0)集",
                                      extraSubtitles: f.subtitles, itemId: iid, fileId: f.id)
                return EpisodeEntry(id: f.id, title: "第 \(f.episode ?? 0) 集", subtitle: "第\(f.season ?? 1)季,第\(f.episode ?? 0)集",
                                    still: f.still ?? item.backdrop ?? item.poster, current: f.id == r.fileId, request: req)
            }
        }
        let vids = r.siblings.filter { $0.isVideo }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let list = vids.isEmpty ? [r.file] : vids
        return list.enumerated().map { i, f in
            EpisodeEntry(id: f.id, title: "第 \(i + 1) 集", subtitle: f.name, still: nil, current: f.id == r.file.id,
                         request: PlayRequest(source: r.source, file: f, siblings: r.siblings))
        }
    }()
    var prevRequest: PlayRequest? {
        guard let i = episodes.firstIndex(where: { $0.current }), i > 0 else { return nil }
        return episodes[i - 1].request
    }
    func playPrev() { if let p = prevRequest, let f = onNext { f(p) } }

    func playNext() {
        guard let n = nextRequest, let f = onNext else { toast = "没有下一集了"; return }
        if let k = playable?.resumeKey { Resume.clear(k) }
        f(n)
    }

    // MARK: intro / credits

    private func loadSegments() async {
        var seg = SkipSegments()
        if PlayerPrefs.onlineSegments, let iid = request.itemId,
           let item = LibraryStore.shared.items.first(where: { $0.id == iid }), let tid = item.tmdbId {
            let lf = item.files.first { $0.id == request.fileId }
            if let r = await IntroDB.fetch(tmdbId: tid, tv: item.isTV, season: lf?.season, episode: lf?.episode, durationMs: lengthMs) { seg = r }
        }
        let m = ManualSegments.get(segKey)
        if let e = m.introEnd { seg.intro = .init(start: 0, end: e); seg.recap = nil }
        if let c = m.creditsStart, lengthMs > c { seg.credits = .init(start: lengthMs - c, end: nil) }
        segments = seg
    }

    func reloadSegments() { Task { await loadSegments() } }

    private func checkSkips() {
        let t = timeMs
        func inside(_ s: SkipSegments.Seg?) -> Bool {
            guard let s else { return false }
            return t >= s.start && t < (s.end ?? lengthMs) - 500
        }
        var pill: (String, Int32?)? = nil
        let list: [(String, String, SkipSegments.Seg?, Bool)] = [
            ("intro", "跳过片头", segments.intro, PlayerPrefs.skipIntro),
            ("recap", "跳过回顾", segments.recap, PlayerPrefs.skipIntro),
            ("credits", "跳过片尾", segments.credits, PlayerPrefs.skipCredits),
            ("preview", "跳过预告", segments.preview, PlayerPrefs.skipPreview),
        ]
        for (k, label, s, auto) in list where inside(s) {
            if auto && !skipped.contains(k) {
                skipped.insert(k)
                doSkip(k, to: s?.end)
                return
            }
            pill = (label, s?.end)
        }
        let cur = activeSkip.map { "\($0.label)\($0.to ?? -1)" }
        let new = pill.map { "\($0.0)\($0.1 ?? -1)" }
        if cur != new { activeSkip = pill.map { (label: $0.0, to: $0.1) } }
    }

    /// to nil = runs to the end: go to next episode when there is one, otherwise jump to the last seconds.
    func doSkip(_ kind: String, to: Int32?) {
        activeSkip = nil
        if let to, to < lengthMs - 3000 {
            engine.seek(ms: to)
            toast = kind == "credits" ? "已跳过片尾（保留彩蛋）" : kind == "preview" ? "已跳过预告" : kind == "recap" ? "已跳过回顾" : "已跳过片头"
        } else if (kind == "credits" || kind == "preview"), PlayerPrefs.autoNext, nextRequest != nil {
            playNext()
        } else {
            engine.seek(ms: max(0, lengthMs - 1500))
        }
    }

    func skipActive() { if let a = activeSkip { doSkip(a.label == "跳过片尾" ? "credits" : "intro", to: a.to) } }

    private func computeBadges() {
        var b: [String] = []
        let name = request.file.name
        let dv = engine.reportsDolbyVision || DolbyBadges.nameHintsDV(name)
        if dv { b.append("杜比视界") }
        let audio = engine.audioBadge
        if var a = audio {
            if DolbyBadges.nameHintsAtmos(name), a != "DTS" { a = "杜比全景声" }
            b.append(a)
        }
        badges = b
        mediaBadges = b
        if b.contains("杜比视界") && engine is VLCEngine {
            toast = EngineChooser.nativeExts.contains(request.file.ext)
                ? "杜比视界：请在设置里打开「苹果原生内核」以正确显示色彩"
                : "VLC 内核显示杜比视界色彩不准，可在设置里把「MKV 播放内核」改为 MPV"
        }
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); badges = [] }
    }

    private func refreshTracks() {
        let subs = engine.subtitleTracks
        if subs != subtitleTracks { subtitleTracks = subs }
        let auds = engine.audioTracks
        if auds != audioTracks { audioTracks = auds }
        let cs = engine.currentSub, ca = engine.currentAudio
        if cs != currentSub { currentSub = cs }
        if ca != currentAudio { currentAudio = ca }
    }

    var searchQuery: String {
        let p = NameParser.parse(request.file.name)
        if let e = p.episode { return "\(p.title) S\(String(format: "%02d", p.season ?? 1))E\(String(format: "%02d", e))" }
        return p.title
    }

    private func autoOnline() async {
        let results = await SubtitleService.search(searchQuery)
        guard let first = results.first else { return }
        await loadOnline(first)
    }

    func loadOnline(_ s: OnlineSubtitle) async {
        do {
            let f = try await SubtitleService.fetch(s)
            engine.addSubtitle(f, select: true)
            loadedSubs.append((s.title, f))
            toast = "已加载字幕：\(s.title)"
        } catch {
            toast = error.localizedDescription
        }
    }

    // MARK: controls
    func toggle() {
        if engine.isPlaying { engine.pause() } else {
            if ended { engine.seek(ms: 0); ended = false }
            engine.play()
        }
        isPlaying.toggle()
    }
    func skip(_ s: Int32) { engine.jump(seconds: s) }
    func seek(_ p: Float) { engine.seek(position: p); position = p }
    func selectSub(_ id: Int32) { engine.selectSub(id); currentSub = id }
    func selectAudio(_ id: Int32) { engine.selectAudio(id); currentAudio = id }
    func setRate(_ r: Float) { engine.setRate(r); rate = r }
    func shiftSubDelay(_ ms: Int) {
        subDelayMs += ms
        engine.setSubDelay(ms: subDelayMs)
        toast = "字幕延迟 \(String(format: "%.1f", Double(subDelayMs) / 1000)) 秒"
    }

    func toggleAICaptions() async {
        if captioner.running { captioner.stop(); toast = "AI 字幕已关闭" }
        else {
            await captioner.start()
            if let st = captioner.status { toast = st }
        }
    }

    func translateSub(_ url: URL, name: String) async {
        guard !translating else { return }
        translating = true
        toast = "正在用系统翻译翻译字幕…"
        defer { translating = false }
        do {
            let f = try await SubtitleTranslator.translateFile(url, bridge: bridge, bilingual: AppSettings.shared.bilingualSubs)
            engine.addSubtitle(f, select: true)
            didPickTrack = true
            toast = "已切换到翻译字幕"
        } catch {
            toast = error.localizedDescription
        }
    }

    func aiTranslateSub(_ url: URL, name: String) async {
        guard !translating else { return }
        translating = true
        toast = "AI 翻译中…"
        defer { translating = false }
        do {
            let f = try await AITranslator.translateFile(url, bilingual: AppSettings.shared.bilingualSubs) { [weak self] d, t in
                if t > 1, d < t { self?.toast = "AI 翻译中 \(d * 100 / t)%" }
            }
            engine.addSubtitle(f, select: true)
            loadedSubs.append(("AI 译 · " + name, f))
            didPickTrack = true
            toast = "已切换到 AI 翻译字幕"
        } catch {
            toast = error.localizedDescription
        }
    }

    @MainActor func setupPiP() {
        guard SamplePiP.supported, UserDefaults.standard.object(forKey: "av.pip") as? Bool ?? true else { return }
        let p = pipBox
        p.isPlaying = { [weak self] in self?.isPlaying ?? false }
        p.setPlaying = { [weak self] on in guard let self else { return }; if on != self.isPlaying { self.toggle() } }
        p.skipBy = { [weak self] s in self?.skip(Int32(s)) }
        p.duration = { [weak self] in Double(self?.lengthMs ?? 0) / 1000 }
        p.current = { [weak self] in Double(self?.timeMs ?? 0) / 1000 }
        p.onState = { [weak self] on in self?.pipActive = on }
        p.attach(to: videoView, auto: UserDefaults.standard.object(forKey: "av.pipAuto") as? Bool ?? true)
    }
    func stop() {
        pipBox.detach()
        captioner.stop()
        if let k = playable?.resumeKey, timeMs > 10_000, !ended { Resume.set(k, timeMs, total: lengthMs) }
        timer?.invalidate()
        timer = nil
        engine.stop()
    }

    static func fmt(_ ms: Int32) -> String {
        let t = Int(ms / 1000)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Hosts the engine view and re-fits it (and VLC's own render subviews) on every size change, e.g. rotation.
final class VideoHost: UIView {
    let inner: UIView
    init(_ v: UIView) {
        inner = v
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        addSubview(v)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        inner.frame = bounds
        for sv in inner.subviews {
            sv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            sv.frame = inner.bounds
        }
        inner.setNeedsLayout()
        inner.layoutIfNeeded()
    }
}

struct VideoSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> VideoHost { VideoHost(view) }
    func updateUIView(_ uiView: VideoHost, context: Context) { uiView.setNeedsLayout() }
}

struct PlayerView: View {
    @StateObject private var c: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Float = 0
    @State private var showOnline = false
    @State private var landscape = false
    @State private var trackSheet: TrackSheetKind?
    @State private var showList = false
    @State private var swipeY: CGFloat = 0
    static var slideIn = false
    @AppStorage("ctl.fwd") private var fwdStep = 10
    @AppStorage("ctl.back") private var backStep = 10
    @AppStorage("ctl.hide") private var hideAfter = 4.0
    @AppStorage("ctl.dtCenter") private var dtCenter = "play"     // play | none
    @AppStorage("ctl.dtSides") private var dtSides = "seek"       // seek | play | none
    @AppStorage("ctl.swipeLevels") private var swipeLevels = true
    @AppStorage("ctl.pinch") private var pinchZoom = true
    @AppStorage("ctl.lockGestures") private var lockGestures = true
    @AppStorage("ctl.longPress") private var longPressOn = true
    @AppStorage("ctl.longRate") private var longRate = 2.0
    @AppStorage("ctl.longSlide") private var longSlide = true
    @AppStorage("ctl.longLock") private var longLockOn = true
    @AppStorage("ctl.longRestore") private var longRestore = "prev"  // prev | one
    @AppStorage("ctl.followRotation") private var followRotation = true
    @AppStorage("ctl.rotateButton") private var rotateButton = true
    @AppStorage("ctl.nextButton") private var nextButton = true
    @AppStorage("ctl.seekButtons") private var seekButtons = true
    @AppStorage("ctl.shotButton") private var shotButton = true
    @AppStorage("ctl.btnSub") private var btnSub = true
    @AppStorage("ctl.btnAudio") private var btnAudio = true
    @AppStorage("ctl.btnSpeed") private var btnSpeed = true
    @AppStorage("ctl.btnSkipMarks") private var btnMarks = true
    @AppStorage("av.fill") private var fillMode = 0
    @AppStorage("av.followVideo") private var followVideo = true
    @State private var locked = false
    @State private var longActive = false
    @State private var longLocked = false
    @State private var rateBeforeLong: Float = 1
    @State private var longSpeed: Double = 2
    @State private var levelHUD: String?
    @State private var curFill = 0
    @State private var screenSize: CGSize = .zero
    @State private var didOrient = false
    static var switching = false
    let onNext: (PlayRequest) -> Void

    init(request: PlayRequest, onNext: @escaping (PlayRequest) -> Void = { _ in }) {
        _c = StateObject(wrappedValue: PlayerController(request))
        self.onNext = onNext
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(view: c.videoView).ignoresSafeArea().offset(y: swipeY)
            if swipeY < -20 {
                VStack { Spacer()
                    Label(c.nextRequest == nil ? "没有下一集了" : (swipeY < -120 ? "松手播放下一集" : "上滑播放下一集"), systemImage: "chevron.up")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10).glass(in: Capsule())
                        .padding(.bottom, 40)
                }.allowsHitTesting(false)
            }
            GeometryReader { g in
                gestures.onAppear { screenSize = g.size }.onChange(of: g.size) { _, v in screenSize = v; c.engine.applyFill(curFill, screen: v) }
            }
            .ignoresSafeArea()
            if let h = levelHUD {
                Text(h).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10).glass(in: Capsule())
                    .allowsHitTesting(false)
            }
            if longActive {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: longLocked ? "lock.fill" : "forward.fill")
                        Text("\(longSpeed, specifier: "%g")× 快进\(longLocked ? "（已锁定，点按恢复）" : "")")
                    }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8).glass(in: Capsule())
                    .padding(.top, 24)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if c.buffering && c.errorText == nil && !showControls {
                ProgressView().controlSize(.large).tint(.white)
                    .padding(22).glass(in: Circle())
            }
            if let e = c.errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                    Text(e).multilineTextAlignment(.center).foregroundStyle(.white)
                    Button("关闭") { close() }.glassButton(prominent: true)
                }
                .padding(24).glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(40)
            }
            LiveCaptionOverlay(captioner: c.captioner)
            if !c.badges.isEmpty && !showControls {
                VStack {
                    HStack(spacing: 8) {
                        ForEach(c.badges, id: \.self) { b in
                            Text(b).font(.caption.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6).glass(in: Capsule())
                        }
                    }.padding(.top, 64)
                    Spacer()
                }.allowsHitTesting(false).transition(.opacity)
            }
            if locked {
                if showControls {
                    HStack {
                        Button { locked = false; scheduleHide() } label: { Image(systemName: "lock.fill").font(.title3).frame(width: 52, height: 52) }
                            .glass(in: Circle(), interactive: true).foregroundStyle(.white)
                            .padding(.leading, 20)
                        Spacer()
                    }
                    .transition(.opacity)
                }
            } else if showControls && trackSheet == nil && !showList { controls.transition(.opacity) }
            if showList { playlistOverlay }
            if let sk = c.activeSkip, !locked, trackSheet == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { c.skipActive() } label: {
                            Label(sk.label, systemImage: "forward.end.fill").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                        .glass(in: Capsule(), interactive: true).foregroundStyle(.white)
                    }
                    .padding(.trailing, 28).padding(.bottom, showControls ? 96 : 40)
                }
                .transition(.opacity)
            }
            if let k = trackSheet { trackPanel(k) }
            if let t = c.toast {
                VStack {
                    Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glass(in: Capsule())
                        .padding(.top, 70)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t) { try? await Task.sleep(nanoseconds: 2_200_000_000); withAnimation { c.toast = nil } }
            }
        }
        .modifier(TranslationHost(bridge: c.bridge))
        .preferredColorScheme(.dark)
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .task { c.onNext = { r in PlayerView.switching = true; onNext(r) }; await c.start(); c.setupPiP(); scheduleHide() }
        .onAppear {
            if PlayerView.slideIn {
                PlayerView.slideIn = false
                swipeY = max(UIScreen.main.bounds.height, 400)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { swipeY = 0 }
            }
            curFill = fillMode
            landscape = true
            if !PlayerView.switching { OrientationLock.set(followRotation ? .allButUpsideDown : .landscape, force: .landscapeRight) }
            PlayerView.switching = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if landscape { OrientationLock.set(followRotation ? .allButUpsideDown : .landscape, force: .landscapeRight) }
            else { setOrientation(portrait: true) }
        }
        .onDisappear { c.stop(); if !PlayerView.switching { OrientationLock.set(.portrait, force: .portrait) } }
        .onChange(of: c.ended) { _, ended in if ended && !PlayerView.switching { close() } }
        .onChange(of: c.timeMs) { _, t in
            guard !didOrient, t > 300 else { return }
            didOrient = true
            c.engine.applyFill(curFill, screen: screenSize)
            let d = c.engine.videoDims
            if followVideo, d.height > d.width * 1.05, d.width > 0 { landscape = false; setOrientation(portrait: true) }
        }
        .sheet(isPresented: $showOnline) { OnlineSubtitleSheet(controller: c) }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: trackSheet)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: showList)
        .animation(.spring, value: c.toast)
    }

    /// Small side panel (landscape: right quarter; portrait: lower part) so the video keeps playing in view.
    private func trackPanel(_ k: TrackSheetKind) -> some View {
        GeometryReader { g in
            let land = g.size.width > g.size.height
            ZStack(alignment: land ? .bottomTrailing : .bottom) {
                Color.black.opacity(0.001).contentShape(Rectangle())
                    .onTapGesture { closePanel() }
                Group {
                    if k == .more { morePanel }
                    else {
                        TrackSheet(c: c, kind: k, close: { closePanel() },
                                   openOnline: { closePanel(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showOnline = true } })
                    }
                }
                    .frame(width: land ? min(max(g.size.width * 0.3, 320), 400) : g.size.width - 16,
                           height: land ? min(g.size.height * 0.68, k == .more ? 330 : 420) : max(g.size.height * 0.38, 300))
                    .padding(.bottom, land ? 70 : 0).padding(.trailing, land ? 12 : 0)
                    .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(8)
                    .transition(.move(edge: land ? .trailing : .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(edges: .vertical)
    }

    private func closePanel() {
        trackSheet = nil
        scheduleHide()
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                // top: close | fill mode, shrink (picture in picture)
                HStack(spacing: 14) {
                    roundButton("xmark") { close() }
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(c.mediaBadges, id: \.self) { b in
                            Text(b).font(.caption.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 7).glass(in: Capsule())
                        }
                    }
                    Spacer()
                    roundButton(curFill == 0 ? "arrow.up.left.and.arrow.down.right.rectangle" : curFill == 1 ? "rectangle.arrowtriangle.2.inward" : "arrow.left.and.right.square") {
                        curFill = (curFill + 1) % 3
                        c.engine.applyFill(curFill, screen: screenSize)
                        flash(["适应屏幕", "填充屏幕", "拉伸铺满"][curFill]); scheduleHide()
                    }
                    roundButton("pip.enter") {
                        if SamplePiP.supported { c.pipBox.toggle() } else { flash("这台设备不支持画中画") }
                    }
                }
                Spacer()
                // middle: lock | rotate
                HStack {
                    roundButton("lock.circle.dotted", size: 52) { locked = true; showControls = true; scheduleHide() }
                    Spacer()
                    if screenSize.width >= screenSize.height { transport }
                    Spacer()
                    if rotateButton {
                        roundButton("rectangle.portrait.rotate", size: 52) { landscape.toggle(); setOrientation(portrait: !landscape); scheduleHide() }
                    }
                }
                if screenSize.width < screenSize.height { transport.scaleEffect(0.8).padding(.top, 12) }
                Spacer()
                // progress
                HStack(spacing: 12) {
                    Text(PlayerController.fmt(scrubbing ? Int32(Float(c.lengthMs) * scrubValue) : c.timeMs))
                    ThinScrubber(value: scrubbing ? scrubValue : c.position,
                                 onChanged: { v in scrubbing = true; scrubValue = v; hideTask?.cancel() },
                                 onEnded: { v in scrubValue = v; c.seek(v); scrubbing = false; scheduleHide() })
                    Text(PlayerController.fmt(c.lengthMs))
                }
                .font(.subheadline.monospacedDigit()).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                // bottom row
                ZStack {
                    HStack(spacing: 22) {
                        Button { showList = true; hideTask?.cancel() } label: { Image(systemName: "list.bullet").font(.title2).frame(width: 44, height: 44) }
                        speedMenu
                        Spacer()
                        Button { trackSheet = .subtitle; hideTask?.cancel() } label: { Image(systemName: "text.bubble").font(.title2).frame(width: 44, height: 44) }
                        Button { trackSheet = .audio; hideTask?.cancel() } label: { Image(systemName: "waveform.circle").font(.title2).frame(width: 44, height: 44) }
                        Button { trackSheet = .more; hideTask?.cancel() } label: { Image(systemName: "gearshape").font(.title2).frame(width: 44, height: 44) }
                    }
                }
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        }
    }

    private var transport: some View {
                    HStack(spacing: 22) {
                        if nextButton, c.prevRequest != nil {
                            roundButton("backward.end.fill", size: 48) { c.playPrev() }
                        }
                        if seekButtons {
                            roundButton(Self.seekIcon("gobackward", backStep), size: 56, font: .title2) { c.skip(Int32(-backStep)); scheduleHide() }
                        }
                        Button { c.toggle(); scheduleHide() } label: {
                            Group {
                                if c.buffering && c.errorText == nil { ProgressView().controlSize(.large).tint(.white) }
                                else { Image(systemName: c.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 32)) }
                            }
                            .frame(width: 96, height: 66)
                        }
                        .glass(in: Capsule(), interactive: true)
                        if seekButtons {
                            roundButton(Self.seekIcon("goforward", fwdStep), size: 56, font: .title2) { c.skip(Int32(fwdStep)); scheduleHide() }
                        }
                        if nextButton, c.nextRequest != nil {
                            roundButton("forward.end.fill", size: 48) { c.playNext() }
                        }
                    }
                    }

    private func roundButton(_ icon: String, size: CGFloat = 52, font: Font = .title3, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(font).frame(width: size, height: size) }
            .glass(in: Circle(), interactive: true)
    }

    /// Episode strip (bottom-left list button): thumbnails with 第 N 集 / 第 S 季, 第 N 集.
    private var playlistOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { showList = false; scheduleHide() }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(c.episodes) { e in
                            Button {
                                showList = false
                                if !e.current { PlayerView.switching = true; onNext(e.request) }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .bottomLeading) {
                                        PosterImage(url: e.still, title: e.title)
                                            .frame(width: 200, height: 112)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        if e.current {
                                            Image(systemName: "waveform").font(.caption.weight(.bold)).padding(6)
                                                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).padding(8)
                                        }
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(e.current ? Color.green : .clear, lineWidth: 2.5))
                                    Text(e.title).font(.headline).lineLimit(1)
                                    Text(e.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                }
                                .frame(width: 200, alignment: .leading)
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain).id(e.id)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .frame(height: 190)
                .onAppear { if let cur = c.episodes.first(where: { $0.current }) { proxy.scrollTo(cur.id, anchor: .center) } }
            }
            .padding(.bottom, 20)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 更多设置 panel (gear button).
    private var morePanel: some View {
        VStack(spacing: 0) {
            Text("更多设置").font(.headline).padding(.vertical, 14)
            Divider().overlay(.white.opacity(0.15))
            ScrollView {
                VStack(spacing: 0) {
                    Menu {
                        Button { ManualSegments.setIntroEnd(c.segKey, c.timeMs); c.reloadSegments(); flash("已把当前位置设为片头结束") } label: { Label("当前位置设为片头结束", systemImage: "forward.frame") }
                        Button { ManualSegments.setCreditsFromEnd(c.segKey, max(0, c.lengthMs - c.timeMs)); c.reloadSegments(); flash("已把当前位置设为片尾开始") } label: { Label("当前位置设为片尾开始", systemImage: "backward.frame") }
                        Button(role: .destructive) { ManualSegments.clear(c.segKey); c.reloadSegments(); flash("已清除手动片头片尾") } label: { Label("清除手动片头片尾", systemImage: "xmark.circle") }
                    } label: { moreRow("forward.end", "跳过片头片尾") { Image(systemName: "chevron.down").foregroundStyle(.white.opacity(0.7)) } }
                    moreRow("backward.end", "上一集 / 下一集按钮") { Toggle("", isOn: $nextButton).labelsHidden() }
                    moreRow("arrow.clockwise", "快退 / 快进按钮") { Toggle("", isOn: $seekButtons).labelsHidden() }
                    Button { closePanel(); snapshot() } label: { moreRow("camera", "截图") { EmptyView() } }
                    Button { closePanel(); showOnline = true } label: { moreRow("magnifyingglass", "搜索字幕") { EmptyView() } }
                }
            }
        }
        .foregroundStyle(.white).tint(.green)
    }
    private func moreRow<T: View>(_ icon: String, _ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 24)
            Text(title).multilineTextAlignment(.leading)
            Spacer()
            trailing()
        }
        .font(.body).padding(.horizontal, 18).frame(minHeight: 54).contentShape(Rectangle())
    }

    private var subtitleMenu: some View {
        Button { trackSheet = .subtitle; hideTask?.cancel() } label: {
            Image(systemName: "captions.bubble").frame(width: 40, height: 40)
        }
        .glass(in: Circle(), interactive: true)
    }

    private var audioMenu: some View {
        Button { trackSheet = .audio; hideTask?.cancel() } label: {
            Image(systemName: "waveform").frame(width: 40, height: 40)
        }
        .glass(in: Circle(), interactive: true)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { (r: Double) in
                Button { c.setRate(Float(r)) } label: {
                    if abs(Double(c.rate) - r) < 0.01 { Label("\(r, specifier: "%g")×", systemImage: "checkmark") } else { Text("\(r, specifier: "%g")×") }
                }
            }
        } label: {
            Text("\(Double(c.rate), specifier: "%g")x").font(.title3.weight(.medium)).frame(minWidth: 44, minHeight: 44)
        }
    }

    private func toggleControls() { showControls.toggle(); if showControls { scheduleHide() } }

    // MARK: gestures

    private var gestures: some View {
        GestureLayer(
            onTap: {
                if longLocked { endLong(force: true); return }
                toggleControls()
            },
            onDoubleTap: { z in
                if locked && !lockGestures { toggleControls(); return }
                let act = z == .center ? (dtCenter == "play" ? "play" : "none") : dtSides
                switch act {
                case "play": c.toggle(); flash(c.isPlaying ? "播放" : "暂停")
                case "seek":
                    if z == .left { c.skip(Int32(-backStep)); flash("后退 \(backStep) 秒") }
                    else if z == .right { c.skip(Int32(fwdStep)); flash("快进 \(fwdStep) 秒") }
                    else { toggleControls() }
                default: toggleControls()
                }
            },
            onLongBegan: {
                guard longPressOn, !(locked && !lockGestures), c.isPlaying else { return }
                if longLocked { return }
                rateBeforeLong = c.rate
                longSpeed = longRate
                c.setRate(Float(longSpeed))
                longActive = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            },
            onLongMoved: { d in
                guard longActive, !longLocked else { return }
                if longLockOn, d.height < -70 { longLocked = true; UIImpactFeedbackGenerator(style: .medium).impactOccurred(); return }
                if longSlide {
                    let steps = (d.width / 40).rounded()
                    let v = min(4, max(1.25, longRate + Double(steps) * 0.25))
                    if v != longSpeed { longSpeed = v; c.setRate(Float(v)) }
                }
            },
            onLongEnded: { if !longLocked { endLong(force: false) } },
            onPan: { began, left, dy, ended in
                guard swipeLevels, !locked else { return }
                if ended { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { levelHUD = nil }; return }
                if began { return }
                if left {
                    SystemLevels.brightness += dy
                    levelHUD = "☀︎ 亮度 \(Int(SystemLevels.brightness * 100))%"
                } else {
                    SystemLevels.volume += Float(dy)
                    levelHUD = "音量 \(Int(SystemLevels.volume * 100))%"
                }
            },
            onSwipe: { dy, ended in
                guard !locked else { return }
                if !ended { swipeY = min(0, dy); return }
                if dy < -120, c.nextRequest != nil {
                    withAnimation(.easeIn(duration: 0.25)) { swipeY = -max(screenSize.height, 400) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { PlayerView.slideIn = true; c.playNext() }
                } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { swipeY = 0 } }
            },
            onPinch: { scale, ended in
                guard pinchZoom, !locked, ended else { return }
                if scale > 1.12 { curFill = 1; flash("填充屏幕") }
                else if scale < 0.9 { curFill = 0; flash("适应屏幕") }
                else { return }
                c.engine.applyFill(curFill, screen: screenSize)
            })
    }

    private func endLong(force: Bool) {
        guard longActive else { return }
        longActive = false; longLocked = false
        c.setRate(longRestore == "one" ? 1 : rateBeforeLong)
    }

    private func snapshot() {
        c.engine.saveSnapshot { ok in flash(ok ? "截图已保存到相册" : "截图失败") }
    }

    private var marksMenu: some View {
        Menu {
            Button { ManualSegments.setIntroEnd(c.segKey, c.timeMs); c.reloadSegments(); flash("已把当前位置设为片头结束") } label: {
                Label("当前位置设为片头结束", systemImage: "forward.frame")
            }
            Button { ManualSegments.setCreditsFromEnd(c.segKey, max(0, c.lengthMs - c.timeMs)); c.reloadSegments(); flash("已把当前位置设为片尾开始") } label: {
                Label("当前位置设为片尾开始", systemImage: "backward.frame")
            }
            Button(role: .destructive) { ManualSegments.clear(c.segKey); c.reloadSegments(); flash("已清除手动片头片尾") } label: {
                Label("清除手动片头片尾", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "forward.end.alt").frame(width: 40, height: 40)
        }
        .glass(in: Circle(), interactive: true)
    }
    static func seekIcon(_ base: String, _ s: Int) -> String {
        [5, 10, 15, 30, 45, 60].contains(s) ? "\(base).\(s)" : base
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(1, hideAfter) * 1_000_000_000))
            if !Task.isCancelled, c.isPlaying || locked, !scrubbing, trackSheet == nil, !showOnline, !showList { showControls = false }
        }
    }
    private func flash(_ s: String) { c.toast = s }
    private func close() { c.stop(); OrientationLock.leavePlayer { dismiss() } }

    private func setOrientation(portrait: Bool) {
        let allowed: UIInterfaceOrientationMask = followRotation ? .allButUpsideDown : (portrait ? .portrait : .landscape)
        OrientationLock.set(allowed, force: portrait ? .portrait : .landscapeRight)
    }
}

struct OnlineSubtitleSheet: View {
    @ObservedObject var controller: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [OnlineSubtitle] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if !SubtitleService.hasOnlineProvider {
                    Text("请先在「设置 › 字幕」里填写射手网(assrt) Token 或 OpenSubtitles API Key。").foregroundStyle(.secondary)
                }
                ForEach(results) { r in
                    Button {
                        Task { await controller.loadOnline(r); dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.title).lineLimit(2)
                            Text("\(r.provider) · \(r.language)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "片名")
            .onSubmit(of: .search) { Task { await run() } }
            .navigationTitle("在线字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { if query.isEmpty { query = controller.searchQuery; await run() } }
        }
    }
    private func run() async {
        loading = true
        results = await SubtitleService.search(query)
        loading = false
    }
}


enum TrackSheetKind: String, Identifiable { case subtitle, audio, more; var id: String { rawValue } }

struct TrackSheet: View {
    @ObservedObject var c: PlayerController
    let kind: TrackSheetKind
    let close: () -> Void
    let openOnline: () -> Void
    @State private var showAISettings = false

    var body: some View {
        NavigationStack {
            List {
                if kind == .subtitle {
                    Section("字幕轨道") {
                        ForEach(c.subtitleTracks, id: \.id) { t in
                            row(t.name, selected: t.id == c.currentSub) { c.selectSub(t.id) }
                        }
                    }
                    Section("字幕延迟（当前 \(String(format: "%.1f", Double(c.subDelayMs) / 1000)) 秒）") {
                        HStack {
                            Button("提前 0.5 秒") { c.shiftSubDelay(-500) }.buttonStyle(.bordered)
                            Spacer()
                            Button("延后 0.5 秒") { c.shiftSubDelay(500) }.buttonStyle(.bordered)
                        }
                    }
                    if UserDefaults.standard.object(forKey: "ai.enabled") as? Bool ?? true {
                    Section("AI 与翻译") {
                        Button { Task { await c.toggleAICaptions() } } label: {
                            Label(c.captioner.running ? "关闭 AI 实时字幕" : "AI 实时字幕", systemImage: "waveform.badge.mic")
                        }
                        ForEach(Array(c.loadedSubs.enumerated()), id: \.offset) { _, s in
                            if UserDefaults.standard.object(forKey: "aitr.enabled") as? Bool ?? true {
                                Button { Task { await c.aiTranslateSub(s.url, name: s.name) } } label: {
                                    Label("AI 翻译：\(s.name)", systemImage: "sparkles").lineLimit(1)
                                }.disabled(c.translating)
                            }
                            Button { Task { await c.translateSub(s.url, name: s.name) } } label: {
                                Label("系统翻译：\(s.name)", systemImage: "translate").lineLimit(1)
                            }.disabled(c.translating)
                        }
                        if c.loadedSubs.isEmpty {
                            Text("内封字幕暂不能翻译。可先「在线搜索字幕」下载外挂字幕，再用 AI 翻译。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button { showAISettings = true } label: {
                            Label("AI 翻译设置（\(AITranslateConfig.shared.provider.title)）", systemImage: "key")
                        }
                    }
                    }
                    SubtitleStyleEditor()
                    Section {
                        Button { openOnline() } label: { Label("在线搜索字幕…", systemImage: "magnifyingglass") }
                    }
                } else {
                    Section("音轨") {
                        ForEach(c.audioTracks, id: \.id) { t in
                            row(t.name, selected: t.id == c.currentAudio) { c.selectAudio(t.id) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 38)
            .containerBackground(.clear, for: .navigation)
            .navigationTitle(kind == .subtitle ? "字幕" : "音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { close() } label: { Image(systemName: "xmark") }
                }
            }
            .navigationDestination(isPresented: $showAISettings) {
                Form { AITranslateSettings() }
                    .scrollContentBackground(.hidden)
                    .containerBackground(.clear, for: .navigation)
                    .navigationTitle("AI 翻译").navigationBarTitleDisplayMode(.inline)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}
