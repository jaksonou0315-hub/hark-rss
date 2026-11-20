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
    func play(_ r: PlayRequest) { request = r }
}

struct TrackInfo: Identifiable, Hashable { var id: Int32; var name: String }

@MainActor
final class PlayerController: NSObject, ObservableObject {
    let player: VLCMediaPlayer = {
        var o = SubtitleStyle.shared.vlcOptions
        if AppSettings.shared.dolbyStereo { o.append("--stereo-mode=1") }
        return VLCMediaPlayer(options: o)
    }()
    private var styleSub: AnyCancellable?
    @Published var badges: [String] = []
    private var didBadge = false
    let request: PlayRequest
    let videoView = UIView()

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
        super.init()
        videoView.backgroundColor = .black
        player.drawable = videoView
        captioner.bridge = bridge
        styleSub = SubtitleStyle.shared.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applySubtitleStyleLive() }
    }

    /// Push the current subtitle style into the running renderer and redraw the active track.
    func applySubtitleStyleLive() {
        let st = SubtitleStyle.shared
        let p = player as NSObject
        func call(_ name: String, _ v: Any) {
            let sel = NSSelectorFromString(name)
            if p.responds(to: sel) { p.perform(sel, with: v) }
        }
        call("setTextRendererFont:", st.vlcFontName as NSString)
        call("setTextRendererFontSize:", NSNumber(value: st.vlcRelFontSize))
        call("setTextRendererFontColor:", NSNumber(value: st.color))
        call("setTextRendererFontForceBold:", NSNumber(value: st.bold))
        let cur = player.currentVideoSubTitleIndex
        if cur >= 0 {
            player.currentVideoSubTitleIndex = -1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.player.currentVideoSubTitleIndex = cur }
        }
    }

    func start() async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let provider = SourceStore.shared.provider(for: request.source)
        do {
            let p = try await provider.playable(request.file)
            playable = p
            let media = VLCMedia(url: p.url)
            for o in p.vlcOptions { media.addOption(o) }
            player.media = media
            player.play()
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
        if isPlaying != player.isPlaying { isPlaying = player.isPlaying }
        let st = player.state
        let buf = (st == .opening || st == .buffering) && !player.isPlaying
        if buf != buffering { buffering = buf }
        let nt = player.time.intValue
        if nt != timeMs { timeMs = nt }
        let nl = player.media?.length.intValue ?? 0
        if nl != lengthMs { lengthMs = nl }
        if lengthMs > 0, player.position != position { position = player.position }
        if st == .error, errorText == nil { errorText = "无法播放此文件（网络错误或格式不受支持）" }
        if st == .ended || (st == .stopped && timeMs > 0 && lengthMs > 0 && lengthMs - timeMs < 3000) {
            ended = true
            if let k = playable?.resumeKey { Resume.clear(k) }
        }
        guard player.isPlaying else { return }

        if !pendingSubs.isEmpty {
            let subs = pendingSubs
            pendingSubs = []
            for (i, u) in subs.enumerated() {
                player.addPlaybackSlave(u, type: .subtitle, enforce: i == 0)
            }
            didPickTrack = true
            toast = "已加载 \(subs.count) 个外挂字幕"
        }
        if !didResume, AppSettings.shared.resumePlayback, let k = playable?.resumeKey {
            didResume = true
            let ms = Resume.get(k)
            if ms > 10_000, lengthMs == 0 || ms < lengthMs - 15_000 {
                player.time = VLCTime(int: ms)
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
        if DolbyBadges.nameHintsDV(name) { b.append("杜比视界") }
        let infos = (player.media?.tracksInformation as? [[String: Any]]) ?? []
        var audio: String?
        for t in infos where (t[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeAudio {
            if let c = (t[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value, let a = DolbyBadges.audioBadge(fourcc: c) {
                if audio == nil || a == "Dolby TrueHD" { audio = a }
            }
        }
        if var a = audio {
            if DolbyBadges.nameHintsAtmos(name), a != "DTS" { a = "杜比全景声" }
            b.append(a)
        }
        badges = b
        if b.contains("杜比视界") {
            toast = EngineChooser.nativeExts.contains(request.file.ext)
                ? "杜比视界：请在设置里打开「苹果原生内核」以正确显示色彩"
                : "MKV 杜比视界色彩可能不准，建议用 MP4 版本（走原生内核）"
        }
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); badges = [] }
    }

    private func refreshTracks() {
        let sn = (player.videoSubTitlesNames as? [String]) ?? []
        let si = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        let subs = zip(si, sn).map { TrackInfo(id: $0.int32Value, name: $1) }
        if subs != subtitleTracks { subtitleTracks = subs }
        let an = (player.audioTrackNames as? [String]) ?? []
        let ai = (player.audioTrackIndexes as? [NSNumber]) ?? []
        let auds = zip(ai, an).map { TrackInfo(id: $0.int32Value, name: $1) }
        if auds != audioTracks { audioTracks = auds }
        let cs = player.currentVideoSubTitleIndex, ca = player.currentAudioTrackIndex
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
            player.addPlaybackSlave(f, type: .subtitle, enforce: true)
            loadedSubs.append((s.title, f))
            toast = "已加载字幕：\(s.title)"
        } catch {
            toast = error.localizedDescription
        }
    }

    // MARK: controls
    func toggle() { if player.isPlaying { player.pause() } else { player.play() }; isPlaying.toggle() }
    func skip(_ s: Int32) { if s > 0 { player.jumpForward(s) } else { player.jumpBackward(-s) } }
    func seek(_ p: Float) { player.position = p; position = p }
    func selectSub(_ id: Int32) { player.currentVideoSubTitleIndex = id; currentSub = id }
    func selectAudio(_ id: Int32) { player.currentAudioTrackIndex = id; currentAudio = id }
    func setRate(_ r: Float) { player.rate = r; rate = r }
    func shiftSubDelay(_ ms: Int) {
        subDelayMs += ms
        player.currentVideoSubTitleDelay = subDelayMs * 1000
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
            player.addPlaybackSlave(f, type: .subtitle, enforce: true)
            didPickTrack = true
            toast = "已切换到翻译字幕"
        } catch {
            toast = error.localizedDescription
        }
    }

    func stop() {
        captioner.stop()
        if let k = playable?.resumeKey, timeMs > 10_000, !ended { Resume.set(k, timeMs, total: lengthMs) }
        timer?.invalidate()
        timer = nil
        player.stop()
    }

    static func fmt(_ ms: Int32) -> String {
        let t = Int(ms / 1000)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

struct VideoSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
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

            if c.buffering && c.errorText == nil {
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
            if showControls { controls.transition(.opacity) }
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
        .onDisappear { c.stop(); setOrientation(portrait: true) }
        .onChange(of: c.ended) { _, ended in if ended { close() } }
        .sheet(isPresented: $showOnline) { OnlineSubtitleSheet(controller: c) }
        .sheet(item: $trackSheet, onDismiss: { scheduleHide() }) { k in
            TrackSheet(c: c, kind: k, openOnline: { trackSheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showOnline = true } })
                .presentationDetents([.medium, .large])
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .animation(.spring, value: c.toast)
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
                        Image(systemName: c.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34)).frame(width: 84, height: 84)
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
    private func close() { c.stop(); dismiss() }

    private func setOrientation(portrait: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: portrait ? .portrait : .landscapeRight)) { _ in }
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
    let openOnline: () -> Void
    @Environment(\.dismiss) private var dismiss

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
                            Button { Task { await c.translateSub(s.url, name: s.name) } } label: {
                                Label("系统翻译：\(s.name)", systemImage: "translate").lineLimit(1)
                            }.disabled(c.translating)
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
            .navigationTitle(kind == .subtitle ? "字幕" : "音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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
