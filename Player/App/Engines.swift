import Foundation
import UIKit
import VLCKitSPM
import Libmpv

/// What PlayerController needs from a playback backend (VLC or mpv).
enum EngineState { case opening, buffering, playing, paused, ended, error }

@MainActor
protocol MediaEngine: AnyObject {
    var view: UIView { get }
    var name: String { get }
    func open(_ p: PlayableMedia)
    func play()
    func pause()
    var isPlaying: Bool { get }
    var state: EngineState { get }
    var timeMs: Int32 { get }
    var lengthMs: Int32 { get }
    var position: Float { get }
    func seek(position: Float)
    func seek(ms: Int32)
    func jump(seconds: Int32)
    var subtitleTracks: [TrackInfo] { get }
    var audioTracks: [TrackInfo] { get }
    var currentSub: Int32 { get }
    var currentAudio: Int32 { get }
    func selectSub(_ id: Int32)
    func selectAudio(_ id: Int32)
    func setRate(_ r: Float)
    func setSubDelay(ms: Int)
    func addSubtitle(_ url: URL, select: Bool)
    func applySubtitleStyle()
    /// "Dolby TrueHD" / "Dolby Digital Plus" / …, nil when not Dolby/DTS
    var audioBadge: String? { get }
    /// true when the stream itself reports Dolby Vision (mpv only)
    var reportsDolbyVision: Bool { get }
    func stop()
}

enum EngineKind: String, CaseIterable { case auto, mpv, vlc
    var label: String {
        switch self { case .auto: return "自动"; case .mpv: return "MPV"; case .vlc: return "VLC" }
    }
}

/// Synchronous on-disk log of the last mpv session (survives a hard crash).
enum MPVLog {
    static let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let file = dir.appendingPathComponent("mpv-hark.log")
    static let mpvFile = dir.appendingPathComponent("mpv-core.log")
    private static let lock = NSLock()
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        try? Data().write(to: file); try? FileManager.default.removeItem(at: mpvFile)
    }
    static func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard let h = try? FileHandle(forWritingTo: file) else {
            try? (line + "\n").data(using: .utf8)?.write(to: file); return
        }
        h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.synchronize(); try? h.close()
    }
    static func combined() -> String {
        let a = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let b = (try? String(contentsOf: mpvFile, encoding: .utf8)) ?? ""
        return a + "\n===== mpv log-file =====\n" + b
    }
}

/// Breadcrumb so a hard crash inside libmpv is noticed on next launch; auto mode then falls back to VLC.
enum MPVGuard {
    private static let d = UserDefaults.standard
    static func mark(_ step: String) { d.set(step, forKey: "mpv.step"); d.synchronize() }
    static func clear() { d.removeObject(forKey: "mpv.step") }
    /// Call once at launch.
    static func checkLastRun() {
        if let s = d.string(forKey: "mpv.step") {
            d.set(s, forKey: "mpv.crashStep"); d.set(true, forKey: "mpv.crashed"); clear()
        }
    }
    static var crashed: Bool { d.bool(forKey: "mpv.crashed") }
    static var crashStep: String? { d.string(forKey: "mpv.crashStep") }
    static func reset() { d.removeObject(forKey: "mpv.crashed"); d.removeObject(forKey: "mpv.crashStep") }
}

extension EngineChooser {
    /// mpv (libplacebo) maps Dolby Vision / HDR correctly; VLC stays for SMB streams (mpv build has no smb) and as fallback.
    static func useMPV(_ r: PlayRequest, local: Bool) -> Bool {
        if r.source.kind == .smb && !local { return false }
        switch AppSettings.shared.mkvEngine {
        case .vlc: return false
        case .mpv: return true
        case .auto:
            if MPVGuard.crashed { return false }
            let n = r.file.name.lowercased()
            return DolbyBadges.nameHintsDV(r.file.name) || n.contains("hdr") || n.contains("2160p") || n.contains("4k")
                || n.contains("uhd") || n.contains("hevc") || n.contains("x265") || n.contains("h265") || n.contains("h.265")
                || DolbyBadges.nameHintsAtmos(r.file.name) || n.contains("truehd")
        }
    }
}

// MARK: - VLC

@MainActor
final class VLCEngine: MediaEngine {
    let player: VLCMediaPlayer = {
        var o = SubtitleStyle.shared.vlcOptions
        if AppSettings.shared.dolbyStereo { o.append("--stereo-mode=1") }
        return VLCMediaPlayer(options: o)
    }()
    let view = UIView()
    var name: String { "VLC" }

    init() {
        view.backgroundColor = .black
        player.drawable = view
    }

    func open(_ p: PlayableMedia) {
        let media = VLCMedia(url: p.url)
        for o in p.vlcOptions { media.addOption(o) }
        player.media = media
        player.play()
    }
    func play() { player.play() }
    func pause() { player.pause() }
    var isPlaying: Bool { player.isPlaying }
    var state: EngineState {
        switch player.state {
        case .opening: return .opening
        case .buffering: return player.isPlaying ? .playing : .buffering
        case .ended: return .ended
        case .error: return .error
        case .paused: return .paused
        case .stopped:
            let t = timeMs, l = lengthMs
            return (t > 0 && l > 0 && l - t < 3000) ? .ended : .paused
        default: return player.isPlaying ? .playing : .paused
        }
    }
    var timeMs: Int32 { player.time.intValue }
    var lengthMs: Int32 { player.media?.length.intValue ?? 0 }
    var position: Float { player.position }
    func seek(position: Float) { player.position = position }
    func seek(ms: Int32) { player.time = VLCTime(int: ms) }
    func jump(seconds s: Int32) { if s > 0 { player.jumpForward(s) } else { player.jumpBackward(-s) } }
    var subtitleTracks: [TrackInfo] {
        let sn = (player.videoSubTitlesNames as? [String]) ?? []
        let si = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        return zip(si, sn).map { TrackInfo(id: $0.int32Value, name: $1) }
    }
    var audioTracks: [TrackInfo] {
        let an = (player.audioTrackNames as? [String]) ?? []
        let ai = (player.audioTrackIndexes as? [NSNumber]) ?? []
        return zip(ai, an).map { TrackInfo(id: $0.int32Value, name: $1) }
    }
    var currentSub: Int32 { player.currentVideoSubTitleIndex }
    var currentAudio: Int32 { player.currentAudioTrackIndex }
    func selectSub(_ id: Int32) { player.currentVideoSubTitleIndex = id }
    func selectAudio(_ id: Int32) { player.currentAudioTrackIndex = id }
    func setRate(_ r: Float) { player.rate = r }
    func setSubDelay(ms: Int) { player.currentVideoSubTitleDelay = ms * 1000 }
    func addSubtitle(_ url: URL, select: Bool) { player.addPlaybackSlave(url, type: .subtitle, enforce: select) }

    func applySubtitleStyle() {
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

    var audioBadge: String? {
        let infos = (player.media?.tracksInformation as? [[String: Any]]) ?? []
        var audio: String?
        for t in infos where (t[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeAudio {
            if let c = (t[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value, let a = DolbyBadges.audioBadge(fourcc: c) {
                if audio == nil || a == "Dolby TrueHD" { audio = a }
            }
        }
        return audio
    }
    var reportsDolbyVision: Bool { false }
    func stop() { player.stop() }
}

// MARK: - mpv (libplacebo: Dolby Vision profile 5/8 reshaping, HDR tone mapping, EDR output)

final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK may set 1x1 to force-complete presentation (mpv#13651)
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }
    // EDR has to be switched on the main thread
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            else { DispatchQueue.main.async { super.wantsExtendedDynamicRangeContent = newValue } }
        }
    }
}

final class MPVView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }
    var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }
    /// mpv's MoltenVK context only re-reads the layer size on a VO reconfig, so rotation needs a nudge.
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero
    private var resizeWork: DispatchWorkItem?
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 1, bounds.height > 1, bounds.size != lastSize {
            let had = lastSize != .zero
            lastSize = bounds.size
            if had {
                resizeWork?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.onResize?() }
                resizeWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
            }
        }
        let sc = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.contentsScale = sc
        let sz = CGSize(width: bounds.width * sc, height: bounds.height * sc)
        if sz.width > 1, sz.height > 1, metalLayer.drawableSize != sz { metalLayer.drawableSize = sz }
    }
}

/// Owns the mpv handle; events are drained on a private queue.
final class MPVCore: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    private let q = DispatchQueue(label: "mpv.events", qos: .userInitiated)
    private let lock = NSLock()
    private var _ended = false, _error: String?, _loaded = false
    var ended: Bool { lock.lock(); defer { lock.unlock() }; return _ended }
    var error: String? { lock.lock(); defer { lock.unlock() }; return _error }
    var loaded: Bool { lock.lock(); defer { lock.unlock() }; return _loaded }

    init(layer: CAMetalLayer) {
        MPVGuard.mark("create")
        guard let m = mpv_create() else { MPVGuard.clear(); return }
        handle = m
        var l = layer
        mpv_set_option(m, "wid", MPV_FORMAT_INT64, &l)
        let s = AppSettings.shared
        let hdrScreen = UIScreen.main.potentialEDRHeadroom > 1.0
        var opts: [(String, String)] = [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"), ("video-rotate", "no"),
            ("target-colorspace-hint", hdrScreen ? "yes" : "no"),
            ("tone-mapping", "auto"), ("hdr-compute-peak", "auto"),
            ("keep-open", "yes"), ("idle", "yes"), ("input-default-bindings", "no"),
            ("cache", "yes"), ("demuxer-max-bytes", "200MiB"), ("demuxer-max-back-bytes", "50MiB"),
            ("demuxer-readahead-secs", "20"), ("network-timeout", "30"),
            ("audio-channels", s.dolbyStereo ? "stereo" : "auto-safe"),
            ("subs-fallback", "yes"), ("sub-auto", "no"), ("osd-level", "0"),
            ("ytdl", "no"), ("load-scripts", "no"),
        ]
        if !s.subtitleEncoding.isEmpty { opts.append(("sub-codepage", s.subtitleEncoding)) }
        opts.append(("sub-fonts-dir", SubtitleStyle.fontsDir.path))
        MPVLog.reset()
        MPVLog.write("iOS \(UIDevice.current.systemVersion), EDR headroom \(UIScreen.main.potentialEDRHeadroom)")
        for (k, v) in opts {
            let r = mpv_set_option_string(m, k, v)
            MPVLog.write("opt \(k)=\(v) -> \(r)")
        }
        mpv_set_option_string(m, "log-file", MPVLog.mpvFile.path)
        mpv_set_option_string(m, "msg-level", "all=debug")
        mpv_request_log_messages(m, "debug")
        mpv_set_wakeup_callback(m, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().drain()
        }, Unmanaged.passUnretained(self).toOpaque())
        MPVGuard.mark("initialize")
        MPVLog.write("mpv_initialize…")
        let r = mpv_initialize(m)
        MPVLog.write("mpv_initialize -> \(r)")
        MPVGuard.mark("ready")
    }

    private func drain() {
        q.async { [weak self] in
            guard let self, let m = self.handle else { return }
            while true {
                guard self.handle != nil, let ev = mpv_wait_event(m, 0) else { break }
                let id = ev.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                switch id {
                case MPV_EVENT_LOG_MESSAGE:
                    if let lm = ev.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                        let pre = lm.prefix.map { String(cString: $0) } ?? ""
                        let lv = lm.level.map { String(cString: $0) } ?? ""
                        let tx = lm.text.map { String(cString: $0) } ?? ""
                        MPVLog.write("[\(pre)] \(lv): \(tx.trimmingCharacters(in: .newlines))")
                    }
                case MPV_EVENT_FILE_LOADED:
                    MPVGuard.mark("loaded")
                    self.lock.lock(); self._loaded = true; self._ended = false; self._error = nil; self.lock.unlock()
                case MPV_EVENT_END_FILE:
                    if let d = ev.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                        self.lock.lock()
                        if d.reason == MPV_END_FILE_REASON_EOF { self._ended = true }
                        if d.reason == MPV_END_FILE_REASON_ERROR {
                            self._error = "无法播放此文件（" + String(cString: mpv_error_string(d.error)) + "）"
                        }
                        self.lock.unlock()
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default: break
                }
            }
        }
    }

    func set(_ k: String, _ v: String) { if let h = handle { mpv_set_property_string(h, k, v) } }
    func getString(_ k: String) -> String? {
        guard let h = handle, let c = mpv_get_property_string(h, k) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }
    /// Forces a VO reconfig (new layer size) by nudging the aspect override imperceptibly, then clearing it.
    func refitVideo() {
        guard handle != nil, let a = getString("video-params/aspect").flatMap(Double.init), a > 0 else { return }
        set("video-aspect-override", String(format: "%.6f", a * 1.0007))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.set("video-aspect-override", "-1") }
    }
    func string(_ k: String) -> String? {
        guard let h = handle, let c = mpv_get_property_string(h, k) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }
    func double(_ k: String) -> Double? {
        guard let h = handle else { return nil }
        var d = 0.0
        return mpv_get_property(h, k, MPV_FORMAT_DOUBLE, &d) >= 0 ? d : nil
    }
    func int(_ k: String) -> Int64? {
        guard let h = handle else { return nil }
        var d: Int64 = 0
        return mpv_get_property(h, k, MPV_FORMAT_INT64, &d) >= 0 ? d : nil
    }
    func flag(_ k: String) -> Bool {
        guard let h = handle else { return false }
        var d: Int32 = 0
        mpv_get_property(h, k, MPV_FORMAT_FLAG, &d)
        return d != 0
    }
    func setFlag(_ k: String, _ v: Bool) {
        guard let h = handle else { return }
        var d: Int32 = v ? 1 : 0
        mpv_set_property(h, k, MPV_FORMAT_FLAG, &d)
    }
    func command(_ args: [String]) {
        guard let h = handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p)) } }
        mpv_command(h, &cargs)
    }
    func commandAsync(_ args: [String]) {
        guard let h = handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p)) } }
        mpv_command_async(h, 0, &cargs)
    }

    func destroy() {
        guard let h = handle else { return }
        handle = nil
        mpv_set_wakeup_callback(h, nil, nil)
        MPVGuard.mark("terminate")
        // same serial queue as drain(), so mpv_wait_event never runs on a destroyed handle
        q.async { mpv_terminate_destroy(h); DispatchQueue.main.async { MPVGuard.clear() } }
    }
}

@MainActor
final class MPVEngine: MediaEngine {
    private let mview = MPVView()
    var view: UIView { mview }
    var name: String { "MPV" }
    private let core: MPVCore
    private var opened = false

    init() {
        mview.backgroundColor = .black
        mview.metalLayer.framebufferOnly = true
        mview.metalLayer.backgroundColor = UIColor.black.cgColor
        mview.metalLayer.contentsScale = UIScreen.main.nativeScale
        core = MPVCore(layer: mview.metalLayer)
        mview.onResize = { [weak core] in core?.refitVideo() }
        applySubtitleStyle()
    }

    func open(_ p: PlayableMedia) {
        var hdrs: [String] = []
        for (k, v) in p.headers {
            if k.caseInsensitiveCompare("User-Agent") == .orderedSame { core.set("user-agent", v) }
            else if k.caseInsensitiveCompare("Referer") == .orderedSame { core.set("referrer", v) }
            else { hdrs.append("\(k): \(v)") }
        }
        for h in hdrs { core.command(["change-list", "http-header-fields", "append", h]) }
        MPVGuard.mark("loadfile")
        core.command(["loadfile", p.url.isFileURL ? p.url.path : p.url.absoluteString, "replace"])
        core.setFlag("pause", false)
        opened = true
    }
    func play() { core.setFlag("pause", false) }
    func pause() { core.setFlag("pause", true) }
    var isPlaying: Bool { core.loaded && !core.flag("pause") && !core.flag("paused-for-cache") && !core.ended }
    var state: EngineState {
        if core.error != nil { return .error }
        if core.ended || core.flag("eof-reached") { return .ended }
        if !core.loaded { return .opening }
        if core.flag("paused-for-cache") || (core.flag("seeking") && core.flag("core-idle")) { return .buffering }
        return core.flag("pause") ? .paused : .playing
    }
    var errorText: String? { core.error }
    var timeMs: Int32 { Int32(((core.double("time-pos") ?? 0) * 1000).rounded()) }
    var lengthMs: Int32 { Int32(((core.double("duration") ?? 0) * 1000).rounded()) }
    var position: Float { Float((core.double("percent-pos") ?? 0) / 100) }
    func seek(position p: Float) { core.commandAsync(["seek", String(format: "%.3f", Double(p) * 100), "absolute-percent"]) }
    func seek(ms: Int32) { core.commandAsync(["seek", String(format: "%.3f", Double(ms) / 1000), "absolute"]) }
    func jump(seconds s: Int32) { core.commandAsync(["seek", String(s), "relative"]) }

    private struct T { var type: String; var id: Int32; var name: String; var codec: String; var dv: Bool }
    private func tracks() -> [T] {
        let n = Int(core.int("track-list/count") ?? 0)
        var out: [T] = []
        for i in 0..<n {
            let b = "track-list/\(i)/"
            guard let type = core.string(b + "type"), let id = core.int(b + "id") else { continue }
            let title = core.string(b + "title") ?? ""
            let lang = core.string(b + "lang") ?? ""
            let codec = core.string(b + "codec") ?? ""
            var parts: [String] = []
            if !title.isEmpty { parts.append(title) }
            if !lang.isEmpty { parts.append(lang) }
            if type == "audio" {
                if let ch = core.int(b + "demux-channel-count") { parts.append("\(ch)ch") }
                if !codec.isEmpty { parts.append(codec.uppercased()) }
            }
            if core.flag(b + "external") { parts.append("外挂") }
            let name = parts.isEmpty ? "轨道 \(id)" : parts.joined(separator: " · ")
            let dv = type == "video" && (core.int(b + "dolby-vision-profile") ?? 0) > 0
            out.append(T(type: type, id: Int32(id), name: name, codec: codec.lowercased(), dv: dv))
        }
        return out
    }
    var subtitleTracks: [TrackInfo] {
        let s = tracks().filter { $0.type == "sub" }
        return s.isEmpty ? [] : [TrackInfo(id: -1, name: "关闭")] + s.map { TrackInfo(id: $0.id, name: $0.name) }
    }
    var audioTracks: [TrackInfo] { tracks().filter { $0.type == "audio" }.map { TrackInfo(id: $0.id, name: $0.name) } }
    var currentSub: Int32 { Int32(core.int("sid") ?? -1) }
    var currentAudio: Int32 { Int32(core.int("aid") ?? -1) }
    func selectSub(_ id: Int32) { core.set("sid", id < 0 ? "no" : String(id)) }
    func selectAudio(_ id: Int32) { core.set("aid", id < 0 ? "no" : String(id)) }
    func setRate(_ r: Float) { core.set("speed", String(format: "%.2f", r)) }
    func setSubDelay(ms: Int) { core.set("sub-delay", String(format: "%.3f", Double(ms) / 1000)) }
    func addSubtitle(_ url: URL, select: Bool) {
        core.commandAsync(["sub-add", url.isFileURL ? url.path : url.absoluteString, select ? "select" : "auto"])
    }

    func applySubtitleStyle() {
        let st = SubtitleStyle.shared
        core.set("sub-font", st.vlcFontName)
        core.set("sub-font-size", String(Int((48 * st.scale / 100).rounded())))
        core.set("sub-color", String(format: "#%06X", st.color & 0xFFFFFF))
        core.set("sub-bold", st.bold ? "yes" : "no")
        core.set("sub-border-size", ["0", "1.5", "3", "4.5"][max(0, min(3, st.outline))])
        core.set("sub-border-color", "#000000")
        if st.background {
            core.set("sub-border-style", "background-box")
            core.set("sub-back-color", String(format: "#%02X000000", Int(st.backgroundOpacity * 255)))
        } else {
            core.set("sub-border-style", "outline-and-shadow")
        }
    }

    var audioBadge: String? {
        var best: String?
        for t in tracks() where t.type == "audio" {
            let a: String?
            switch t.codec {
            case "truehd", "mlp": a = "Dolby TrueHD"
            case "eac3": a = "Dolby Digital Plus"
            case "ac3": a = "Dolby Digital"
            case "dts": a = "DTS"
            default: a = nil
            }
            if let a, best == nil || a == "Dolby TrueHD" { best = a }
        }
        return best
    }
    var reportsDolbyVision: Bool { tracks().contains { $0.dv } }

    func stop() {
        core.command(["stop"])
        core.destroy()
    }
}
