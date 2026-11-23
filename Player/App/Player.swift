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
        if phone {
            OrientationLock.set(.allButUpsideDown, force: .landscapeRight)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { UIView.setAnimationsEnabled(true) }
        }
    }
}

struct TrackInfo: Identifiable, Hashable { var id: Int32; var name: String }

@MainActor
final class PlayerController: NSObject, ObservableObject {
    let engine: MediaEngine
    private var styleSub: AnyCancellable?
    @Published var badges: [String] = []
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
        }
        guard playing else { return }
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

    func stop() {
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

    init(request: PlayRequest) { _c = StateObject(wrappedValue: PlayerController(request)) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(view: c.videoView).ignoresSafeArea()
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { c.skip(-10); flash("后退 10 秒") }
                    .onTapGesture { toggleControls() }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { c.skip(10); flash("快进 10 秒") }
                    .onTapGesture { toggleControls() }
            }
            .ignoresSafeArea()

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
            if !c.badges.isEmpty {
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
            if showControls && trackSheet == nil { controls.transition(.opacity) }
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
        .task { await c.start(); scheduleHide() }
        .onAppear { landscape = true; OrientationLock.set(.allButUpsideDown, force: .landscapeRight) }
        .onDisappear { c.stop(); OrientationLock.set(.portrait, force: .portrait) }
        .onChange(of: c.ended) { _, ended in if ended { close() } }
        .sheet(isPresented: $showOnline) { OnlineSubtitleSheet(controller: c) }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: trackSheet)
        .animation(.spring, value: c.toast)
    }

    /// Small side panel (landscape: right quarter; portrait: lower part) so the video keeps playing in view.
    private func trackPanel(_ k: TrackSheetKind) -> some View {
        GeometryReader { g in
            let land = g.size.width > g.size.height
            ZStack(alignment: land ? .trailing : .bottom) {
                Color.black.opacity(0.001).contentShape(Rectangle())
                    .onTapGesture { closePanel() }
                TrackSheet(c: c, kind: k, close: { closePanel() },
                           openOnline: { closePanel(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showOnline = true } })
                    .frame(width: land ? min(max(g.size.width * 0.27, 300), 380) : g.size.width - 16,
                           height: land ? g.size.height - 16 : max(g.size.height * 0.38, 300))
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
        VStack {
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button { close() } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                        .glass(in: Circle(), interactive: true)
                    Text(c.title).font(.headline).lineLimit(1).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 40)
                        .glass(in: Capsule())
                    Spacer()
                    subtitleMenu
                    audioMenu
                    speedMenu
                    Button { landscape.toggle(); setOrientation(portrait: !landscape) } label: {
                        Image(systemName: "rotate.right").frame(width: 40, height: 40)
                    }.glass(in: Circle(), interactive: true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.top, 8)

            Spacer()

            GlassGroup(spacing: 24) {
                HStack(spacing: 28) {
                    Button { c.skip(-10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.title2).frame(width: 60, height: 60) }
                        .glass(in: Circle(), interactive: true)
                    Button { c.toggle(); scheduleHide() } label: {
                        Group {
                            if c.buffering && c.errorText == nil { ProgressView().controlSize(.large).tint(.white) }
                            else { Image(systemName: c.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34)) }
                        }
                        .frame(width: 84, height: 84)
                    }
                    .glass(in: Circle(), interactive: true)
                    Button { c.skip(10); scheduleHide() } label: { Image(systemName: "goforward.10").font(.title2).frame(width: 60, height: 60) }
                        .glass(in: Circle(), interactive: true)
                }
            }
            .foregroundStyle(.white)

            Spacer()

            VStack(spacing: 2) {
                ThinScrubber(value: scrubbing ? scrubValue : c.position,
                             onChanged: { v in scrubbing = true; scrubValue = v; hideTask?.cancel() },
                             onEnded: { v in scrubValue = v; c.seek(v); scrubbing = false; scheduleHide() })
                HStack {
                    Text(PlayerController.fmt(scrubbing ? Int32(Float(c.lengthMs) * scrubValue) : c.timeMs))
                    Spacer()
                    Text("-" + PlayerController.fmt(max(0, c.lengthMs - (scrubbing ? Int32(Float(c.lengthMs) * scrubValue) : c.timeMs))))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.6), radius: 2)
            }
            .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 14)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        }
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
            Image(systemName: "gauge.with.dots.needle.67percent").frame(width: 40, height: 40)
        }
        .glass(in: Circle(), interactive: true)
    }

    private func toggleControls() { showControls.toggle(); if showControls { scheduleHide() } }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled, c.isPlaying, !scrubbing, trackSheet == nil, !showOnline { showControls = false }
        }
    }
    private func flash(_ s: String) { c.toast = s }
    private func close() { c.stop(); OrientationLock.leavePlayer { dismiss() } }

    private func setOrientation(portrait: Bool) {
        OrientationLock.set(.allButUpsideDown, force: portrait ? .portrait : .landscapeRight)
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


enum TrackSheetKind: String, Identifiable { case subtitle, audio; var id: String { rawValue } }

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
                    Section("AI 与翻译") {
                        Button { Task { await c.toggleAICaptions() } } label: {
                            Label(c.captioner.running ? "关闭 AI 实时字幕" : "AI 实时字幕", systemImage: "waveform.badge.mic")
                        }
                        ForEach(Array(c.loadedSubs.enumerated()), id: \.offset) { _, s in
                            Button { Task { await c.aiTranslateSub(s.url, name: s.name) } } label: {
                                Label("AI 翻译：\(s.name)", systemImage: "sparkles").lineLimit(1)
                            }.disabled(c.translating)
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
