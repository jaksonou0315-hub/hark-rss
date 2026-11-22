import Foundation

struct OnlineSubtitle: Identifiable, Hashable {
    var id: String
    var title: String
    var language: String
    var provider: String     // 射手网(assrt) | OpenSubtitles
    var ref: String          // assrt id | OpenSubtitles file_id
}

enum SubtitleService {
    /// External subtitle files next to a video: same base name first; if the folder holds a single video, all subtitles.
    static func sidecars(for video: RemoteFile, in siblings: [RemoteFile]) -> [RemoteFile] {
        Sidecars(siblings, lang: AppSettings.shared.preferredSubLang).for(video)
    }

    /// Built once per folder: the subtitle list, its lowercased names and the video count,
    /// so matching N videos in a folder costs N × subs instead of N × all files (was quadratic every scan tick).
    struct Sidecars {
        private let subs: [(base: String, file: RemoteFile, score: Int)]
        private let singleVideo: Bool
        init(_ siblings: [RemoteFile], lang: String) {
            var s: [(String, RemoteFile, Int)] = []
            var videos = 0
            for f in siblings {
                if f.isDir { continue }
                let e = f.ext
                if FileKinds.subtitle.contains(e) {
                    if !["idx", "sub", "sup", "lrc"].contains(e) {
                        s.append((f.baseName.lowercased(), f, SubtitleService.score(f.name, lang: lang)))
                    }
                } else if f.isVideo { videos += 1 }
            }
            subs = s.sorted { $0.2 > $1.2 }      // Chinese tracks first
            singleVideo = videos == 1
        }
        var isEmpty: Bool { subs.isEmpty }
        func `for`(_ video: RemoteFile) -> [RemoteFile] {
            if subs.isEmpty { return [] }
            let base = video.baseName.lowercased()
            let m = subs.filter { $0.base.hasPrefix(base) }.map(\.file)
            return m.isEmpty && singleVideo ? subs.map(\.file) : m
        }
    }

    static func score(_ name: String) -> Int { score(name, lang: AppSettings.shared.preferredSubLang) }

    nonisolated static func score(_ name: String, lang pref: String) -> Int {
        let n = name.lowercased()
        if pref == "zh" {
            if n.contains("chs") || n.contains("sc") || n.contains("简") || n.contains("zh-cn") || n.contains("zh-hans") || n.contains(".zh") { return 3 }
            if n.contains("cht") || n.contains("tc") || n.contains("繁") || n.contains("zh-tw") || n.contains("zh-hant") || n.contains("chi") { return 2 }
        } else if pref == "en" {
            if n.contains("eng") || n.contains(".en") { return 3 }
        }
        return n.hasSuffix(".ass") ? 1 : 0
    }

    /// Does this embedded track name match the preferred language?
    static func trackMatchesPreferred(_ name: String) -> Bool {
        let n = name.lowercased()
        switch AppSettings.shared.preferredSubLang {
        case "zh": return ["chi", "chs", "cht", "zho", "chinese", "中", "简", "繁", "zh", "mandarin", "粤"].contains { n.contains($0) }
        case "en": return n.contains("eng") || n.contains("english")
        default: return false
        }
    }

    /// Decode any subtitle bytes (UTF-8 / UTF-16 / GB18030 / Big5) and save as UTF-8 temp file.
    static func saveTemp(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ext = (name as NSString).pathExtension.lowercased()
        if !FileKinds.subtitle.contains(ext) { ext = "srt" }
        let url = dir.appendingPathComponent(UUID().uuidString + "." + ext)
        if let s = decode(data) { try s.data(using: .utf8)!.write(to: url) } else { try data.write(to: url) }
        return url
    }

    static func decode(_ d: Data) -> String? {
        if let s = String(data: d, encoding: .utf8) { return s }
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]), let s = String(data: d, encoding: .utf16) { return s }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: d, encoding: gb) { return s }
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        return String(data: d, encoding: big5)
    }

    // MARK: online search

    static var hasOnlineProvider: Bool {
        !AppSettings.shared.assrtToken.trimmed.isEmpty || !AppSettings.shared.openSubtitlesKey.trimmed.isEmpty
    }

    static func search(_ query: String) async -> [OnlineSubtitle] {
        async let a = searchAssrt(query)
        async let o = searchOpenSubtitles(query)
        return (await a) + (await o)
    }

    private static func searchAssrt(_ q: String) async -> [OnlineSubtitle] {
        let token = AppSettings.shared.assrtToken.trimmed
        guard !token.isEmpty, let u = URL(string: "https://api.assrt.net/v1/sub/search?token=\(token)&q=\(q.urlQueryEncoded)&cnt=20&pos=0") else { return [] }
        guard let o = try? await HTTP.json(HTTP.request(u)) else { return [] }
        return (o.dict("sub")?.arr("subs") ?? []).compactMap { s in
            guard let id = s.str("id") else { return nil }
            let lang = s.dict("lang")?.str("desc") ?? ""
            return OnlineSubtitle(id: "assrt-\(id)", title: s.str("native_name").flatMap { $0.isEmpty ? nil : $0 } ?? s.str("videoname") ?? "字幕 \(id)",
                                  language: lang, provider: "射手网", ref: id)
        }
    }

    private static func searchOpenSubtitles(_ q: String) async -> [OnlineSubtitle] {
        let key = AppSettings.shared.openSubtitlesKey.trimmed
        let langs = AppSettings.shared.preferredSubLang == "en" ? "en" : "zh-cn,zh-tw,en"
        guard !key.isEmpty, let u = URL(string: "https://api.opensubtitles.com/api/v1/subtitles?query=\(q.urlQueryEncoded)&languages=\(langs)") else { return [] }
        guard let o = try? await HTTP.json(HTTP.request(u, headers: ["Api-Key": key, "User-Agent": "HarkPlayer v1.0"])) else { return [] }
        return o.arr("data").compactMap { d in
            guard let a = d.dict("attributes"), let f = a.arr("files").first, let fid = f.str("file_id") else { return nil }
            return OnlineSubtitle(id: "os-\(fid)", title: a.str("release") ?? f.str("file_name") ?? "字幕", language: a.str("language") ?? "", provider: "OpenSubtitles", ref: fid)
        }
    }

    /// Download one online subtitle to a local UTF-8 file.
    static func fetch(_ s: OnlineSubtitle) async throws -> URL {
        if s.provider == "OpenSubtitles" {
            let key = AppSettings.shared.openSubtitlesKey.trimmed
            let o = try await HTTP.json(HTTP.request(URL(string: "https://api.opensubtitles.com/api/v1/download")!, method: "POST",
                                                     headers: ["Api-Key": key, "User-Agent": "HarkPlayer v1.0", "Accept": "application/json"],
                                                     json: ["file_id": Int(s.ref) ?? 0]))
            guard let link = o.str("link"), let u = URL(string: link) else { throw AppError.message(o.str("message") ?? "下载失败") }
            let (d, _) = try await HTTP.data(URLRequest(url: u))
            return try saveTemp(d, name: o.str("file_name") ?? "sub.srt")
        }
        let token = AppSettings.shared.assrtToken.trimmed
        let o = try await HTTP.json(HTTP.request(URL(string: "https://api.assrt.net/v1/sub/detail?token=\(token)&id=\(s.ref)")!))
        guard let sub = o.dict("sub")?.arr("subs").first else { throw AppError.message("找不到字幕详情") }
        let files = sub.arr("filelist").filter {
            let n = ($0.str("f") ?? "").lowercased()
            return n.hasSuffix(".srt") || n.hasSuffix(".ass") || n.hasSuffix(".ssa") || n.hasSuffix(".vtt")
        }.sorted { score($0.str("f") ?? "") > score($1.str("f") ?? "") }
        var url: URL?
        var name = "sub.srt"
        if let f = files.first, let us = f.str("url") { url = URL(string: us); name = f.str("f") ?? name }
        else if let us = sub.str("url"), let fn = sub.str("filename"), FileKinds.subtitle.contains((fn as NSString).pathExtension.lowercased()) {
            url = URL(string: us); name = fn
        }
        guard let url else { throw AppError.message("该字幕为压缩包，暂不支持直接加载，请换一个") }
        let (d, _) = try await HTTP.data(URLRequest(url: url))
        return try saveTemp(d, name: name)
    }
}
