import Foundation
import SwiftUI
import VLCKitSPM

/// Video / audio / subtitle details of one file: filename hints first, then a VLC header probe (cached).
struct MediaInfo: Codable, Hashable {
    struct Audio: Codable, Hashable { var codec: String; var channels: String; var language: String; var title: String; var spatial: String }
    struct Sub: Codable, Hashable { var language: String; var title: String; var codec: String; var external: Bool }
    var colorRange = ""          // SDR / HDR10 / HDR10+ / 杜比视界 / HLG
    var codec = ""               // H.265 / H.264 / AV1 …
    var resolution = ""          // 3840×2160 (4K)
    var fps = ""
    var size: Int64 = 0
    var container = ""
    var audios: [Audio] = []
    var subs: [Sub] = []
    var probed = false
}

@MainActor
final class MediaInfoStore: ObservableObject {
    static let shared = MediaInfoStore()
    @Published private(set) var infos: [String: MediaInfo] = [:]
    private var running = Set<String>()
    private let key = "mediainfo.v1"

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode([String: MediaInfo].self, from: d) { infos = v }
    }
    private func persist() {
        let probed = infos.filter(\.value.probed)
        if let d = try? JSONEncoder().encode(probed) { UserDefaults.standard.set(d, forKey: key) }
    }

    func info(_ f: LibraryFile) -> MediaInfo { infos[f.id] ?? Self.guess(f) }
    func isProbing(_ id: String) -> Bool { running.contains(id) }

    func probe(_ f: LibraryFile) async {
        if infos[f.id]?.probed == true || running.contains(f.id) { return }
        guard let src = SourceStore.shared.source(f.sourceId) else { return }
        running.insert(f.id); objectWillChange.send()
        defer { running.remove(f.id); objectWillChange.send() }
        let provider = SourceStore.shared.provider(for: src)
        guard let p = try? await DownloadStore.shared.playable(provider, f.file) else { return }
        let tracks = await VLCProbe.tracks(p)
        var m = Self.guess(f)
        if !tracks.isEmpty { Self.merge(&m, tracks) }
        m.probed = true
        infos[f.id] = m
        persist()
    }

    // MARK: filename

    static func guess(_ f: LibraryFile) -> MediaInfo {
        var m = MediaInfo()
        let n = f.file.name.lowercased()
        m.size = f.file.size
        m.container = f.file.ext.uppercased()
        if DolbyBadges.nameHintsDV(f.file.name) { m.colorRange = "杜比视界" }
        else if n.contains("hdr10+") || n.contains("hdr10plus") || n.contains("hdr10p") { m.colorRange = "HDR10+" }
        else if n.contains("hlg") { m.colorRange = "HLG" }
        else if n.contains("hdr") { m.colorRange = "HDR10" }
        if n.contains("x265") || n.contains("h265") || n.contains("h.265") || n.contains("hevc") { m.codec = "H.265" }
        else if n.contains("x264") || n.contains("h264") || n.contains("h.264") || n.contains("avc") { m.codec = "H.264" }
        else if n.contains("av1") { m.codec = "AV1" }
        if n.contains("2160p") || n.contains("4k") || n.contains("uhd") { m.resolution = "4K" }
        else if n.contains("1080p") { m.resolution = "1080p" } else if n.contains("720p") { m.resolution = "720p" }
        var a = MediaInfo.Audio(codec: "", channels: "", language: "", title: "", spatial: "")
        if n.contains("truehd") { a.codec = "TrueHD" }
        else if n.contains("ddp") || n.contains("eac3") || n.contains("e-ac-3") || n.contains("dd+") { a.codec = "EAC3" }
        else if n.contains("dts-hd") || n.contains("dtshd") { a.codec = "DTS-HD MA" }
        else if n.contains("dts") { a.codec = "DTS" }
        else if n.contains("aac") { a.codec = "AAC" }
        else if n.contains("flac") { a.codec = "FLAC" }
        else if n.contains("ac3") || n.contains(".dd5") || n.contains("dd5.1") { a.codec = "AC3" }
        if DolbyBadges.nameHintsAtmos(f.file.name) { a.spatial = "Atmos" }
        if let r = n.range(of: #"[2-9]\.[01]"#, options: .regularExpression) { a.channels = String(n[r]) }
        if !a.codec.isEmpty || !a.spatial.isEmpty || !a.channels.isEmpty { m.audios = [a] }
        m.subs = f.subtitles.map { MediaInfo.Sub(language: lang(from: $0.name), title: $0.name, codec: $0.ext.uppercased(), external: true) }
        return m
    }

    private static func lang(from name: String) -> String {
        let n = name.lowercased()
        let table: [(String, String)] = [("chs", "简体中文"), ("sc", "简体中文"), ("zh-hans", "简体中文"), ("cht", "繁体中文"), ("tc", "繁体中文"),
                                         ("zh-hant", "繁体中文"), ("zh", "中文"), ("chi", "中文"), ("eng", "英语"), ("en", "英语"),
                                         ("jpn", "日语"), ("ja", "日语"), ("kor", "韩语"), ("ko", "韩语"), ("tha", "泰语"), ("th", "泰语")]
        let parts = Set(n.split(whereSeparator: { ".-_ []()".contains($0) }).map(String.init))
        for (k, v) in table where parts.contains(k) { return v }
        if n.contains("简") { return "简体中文" }
        if n.contains("繁") { return "繁体中文" }
        return ""
    }

    // MARK: probe merge

    private static func merge(_ m: inout MediaInfo, _ tracks: [[String: Any]]) {
        var audios: [MediaInfo.Audio] = []
        var subs: [MediaInfo.Sub] = []
        let hintSpatial = m.audios.first?.spatial ?? ""
        for t in tracks {
            let type = t[VLCMediaTracksInformationType] as? String ?? ""
            let fourcc = (t[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value ?? 0
            let lang = langName(t[VLCMediaTracksInformationLanguage] as? String ?? "")
            let desc = t[VLCMediaTracksInformationDescription] as? String ?? ""
            switch type {
            case VLCMediaTracksInformationTypeVideo:
                let c = codecName(fourcc, type: type)
                if !c.isEmpty { m.codec = c }
                let w = (t[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue ?? 0
                let h = (t[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue ?? 0
                if w > 0 && h > 0 {
                    let tag = w >= 3200 || h >= 2000 ? " (4K)" : h >= 1000 || w >= 1900 ? " (1080p)" : h >= 700 ? " (720p)" : ""
                    m.resolution = "\(w)×\(h)" + tag
                }
                let fr = (t[VLCMediaTracksInformationFrameRate] as? NSNumber)?.doubleValue ?? 0
                let fb = (t[VLCMediaTracksInformationFrameRateDenominator] as? NSNumber)?.doubleValue ?? 0
                if fr > 0 && fb > 0 { m.fps = String(format: "%.3g fps", fr / fb) }
                if m.colorRange.isEmpty { m.colorRange = "SDR" }
            case VLCMediaTracksInformationTypeAudio:
                let ch = (t[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue ?? 0
                let layout: String = ch == 8 ? "7.1" : ch == 6 ? "5.1" : ch == 2 ? "立体声" : ch == 1 ? "单声道" : ch > 0 ? "\(ch) 声道" : ""
                let c = codecName(fourcc, type: type)
                var spatial = ""
                if desc.lowercased().contains("atmos") || ((c == "EAC3" || c == "TrueHD") && !hintSpatial.isEmpty) { spatial = "Atmos" }
                if desc.lowercased().contains("dts:x") || desc.lowercased().contains("dts-x") { spatial = "DTS:X" }
                audios.append(.init(codec: c, channels: layout, language: lang, title: desc, spatial: spatial))
            case VLCMediaTracksInformationTypeText:
                subs.append(.init(language: lang, title: desc, codec: codecName(fourcc, type: type), external: false))
            default: break
            }
        }
        if !audios.isEmpty { m.audios = audios }
        m.subs = subs + m.subs
    }

    private static func codecName(_ fourcc: UInt32, type: String) -> String {
        let raw = String(bytes: [UInt8(fourcc & 0xff), UInt8((fourcc >> 8) & 0xff), UInt8((fourcc >> 16) & 0xff), UInt8(fourcc >> 24)], encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let map: [String: String] = [
            "hevc": "H.265", "h265": "H.265", "h264": "H.264", "avc1": "H.264", "av01": "AV1", "vp90": "VP9", "vp80": "VP8",
            "mpgv": "MPEG-2", "mp4v": "MPEG-4", "wvc1": "VC-1", "eac3": "EAC3", "a52": "AC3", "a52b": "AC3", "mlp": "TrueHD",
            "trhd": "TrueHD", "dts": "DTS", "dtsh": "DTS-HD", "mp4a": "AAC", "flac": "FLAC", "opus": "Opus", "vorb": "Vorbis",
            "mpga": "MP3", "mp3": "MP3", "lpcm": "PCM", "araw": "PCM", "subt": "SRT", "ssa": "ASS", "ass": "ASS",
            "pgs": "PGS", "pgss": "PGS", "spu": "VobSub", "dvbs": "DVB", "tx3g": "TX3G", "webv": "WebVTT", "wvtt": "WebVTT",
        ]
        return map[raw] ?? raw.uppercased()
    }

    private static func langName(_ code: String) -> String {
        let c = code.lowercased()
        let map = ["chi": "中文", "zho": "中文", "zh": "中文", "chs": "简体中文", "cht": "繁体中文", "eng": "英语", "en": "英语",
                   "jpn": "日语", "ja": "日语", "kor": "韩语", "ko": "韩语", "tha": "泰语", "th": "泰语", "fre": "法语", "fra": "法语",
                   "ger": "德语", "deu": "德语", "spa": "西班牙语", "es": "西班牙语", "ita": "意大利语", "rus": "俄语", "por": "葡萄牙语",
                   "und": ""]
        return map[c] ?? code
    }
}

/// Reads track info from a remote file header with VLC (no playback).
@MainActor
final class VLCProbe: NSObject, VLCMediaDelegate {
    private var cont: CheckedContinuation<[[String: Any]], Never>?
    private var media: VLCMedia?

    static func tracks(_ p: PlayableMedia) async -> [[String: Any]] {
        let probe = VLCProbe()
        return await probe.run(p)
    }

    private func run(_ p: PlayableMedia) async -> [[String: Any]] {
        await withCheckedContinuation { c in
            cont = c
            let m = VLCMedia(url: p.url)
            for o in p.vlcOptions { m.addOption(o) }
            m.delegate = self
            media = m
            m.parse(options: [.parseNetwork, .fetchNetwork], timeout: 20_000)
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in self?.finish() }
        }
    }

    nonisolated func mediaDidFinishParsing(_ aMedia: VLCMedia) {
        Task { @MainActor in self.finish() }
    }

    private func finish() {
        guard let c = cont else { return }
        cont = nil
        let t = (media?.tracksInformation as? [[String: Any]]) ?? []
        media?.delegate = nil
        media = nil
        c.resume(returning: t)
    }
}

// MARK: - cards

struct MediaInfoCards: View {
    let file: LibraryFile
    @ObservedObject private var store = MediaInfoStore.shared

    var body: some View {
        let m = store.info(file)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("媒体信息").font(.title2.bold())
                if store.isProbing(file.id) { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    card("视频", "film") {
                        row("色彩范围", m.colorRange)
                        row("文件大小", m.size > 0 ? ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file) : "")
                        row("编码", m.codec)
                        row("分辨率", m.resolution)
                        row("帧率", m.fps)
                        row("容器", m.container)
                    }
                    if m.audios.isEmpty {
                        card("音频", "music.note") { row("编码", "") }
                    } else {
                        card(m.audios.count > 1 ? "音频（\(m.audios.count) 条音轨）" : "音频", "music.note") {
                            ForEach(Array(m.audios.enumerated()), id: \.offset) { i, a in
                                if m.audios.count > 1 {
                                    Text("音轨 \(i + 1)" + (a.language.isEmpty ? "" : " · \(a.language)")).font(.footnote.bold()).padding(.top, i == 0 ? 0 : 6)
                                }
                                row("编码", a.codec)
                                row("空间音频", a.spatial)
                                row("声道布局", a.channels)
                                if m.audios.count == 1 { row("语言", a.language) }
                                if !a.title.isEmpty && a.title.lowercased() != a.codec.lowercased() { row("标题", a.title) }
                            }
                        }
                    }
                    card(m.subs.isEmpty ? "字幕" : "字幕（\(m.subs.count)）", "captions.bubble") {
                        if m.subs.isEmpty {
                            Text(m.probed ? "没有字幕" : "读取中…").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                        }
                        ForEach(Array(m.subs.enumerated()), id: \.offset) { i, s in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(i + 1).").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text([s.language.isEmpty ? "未知语言" : s.language, s.codec].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.subheadline.weight(.medium))
                                    let t = [s.title, s.external ? "外挂" : "内封"].filter { !$0.isEmpty }.joined(separator: " · ")
                                    Text(t).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .task(id: file.id) { await store.probe(file) }
    }

    private func card<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            VStack(alignment: .leading, spacing: 7) { content() }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 270, alignment: .topLeading)
        .frame(minHeight: 190, alignment: .topLeading)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        if !v.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(k + "：").font(.subheadline).frame(width: 84, alignment: .leading)
                Text(v).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            }
        }
    }
}
