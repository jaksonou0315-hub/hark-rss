import Foundation
import AMSMB2

protocol SourceProvider: AnyObject {
    var source: MediaSource { get }
    /// nil = root
    func list(_ dir: RemoteFile?) async throws -> [RemoteFile]
    func playable(_ file: RemoteFile) async throws -> PlayableMedia
    /// Raw bytes of a small file (subtitles).
    func fetchData(_ file: RemoteFile) async throws -> Data
}

extension SourceProvider {
    func fetchData(_ file: RemoteFile) async throws -> Data {
        let p = try await playable(file)
        if p.url.isFileURL { return try Data(contentsOf: p.url) }
        var r = URLRequest(url: p.url)
        for (k, v) in p.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, _) = try await HTTP.data(r)
        return d
    }
    func resumeKey(_ f: RemoteFile) -> String { source.id.uuidString + ":" + f.id }
}

enum Providers {
    static func make(_ s: MediaSource) -> SourceProvider {
        switch s.kind {
        case .local: return LocalProvider(s)
        case .smb: return SMBProvider(s)
        case .webdav: return WebDAVProvider(s)
        case .emby, .jellyfin: return EmbyProvider(s)
        case .aliyun: return AliyunProvider(s)
        case .pan115: return Pan115Provider(s)
        case .baidu: return BaiduProvider(s)
        case .quark: return QuarkTVProvider(s)
        case .guangya: return GuangyaProvider(s)
        case .pan123: return Pan123Provider(s)
        case .onedrive: return OneDriveProvider(s)
        case .dropbox: return DropboxProvider(s)
        case .box: return BoxProvider(s)
        case .pcloud: return PCloudProvider(s)
        case .yandex: return YandexProvider(s)
        }
    }

    static func sortFiles(_ a: [RemoteFile]) -> [RemoteFile] {
        a.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Local (Documents, filled via Files app / iTunes sharing)

final class LocalProvider: SourceProvider {
    let source: MediaSource
    init(_ s: MediaSource) { source = s }
    private var root: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        let url = dir.map { root.appendingPathComponent($0.path) } ?? root
        let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
        let base = dir?.path ?? ""
        return Providers.sortFiles(items.map { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let p = base + "/" + u.lastPathComponent
            return RemoteFile(id: p, name: u.lastPathComponent, path: p, isDir: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0))
        })
    }
    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        PlayableMedia(url: root.appendingPathComponent(file.path), title: file.name, resumeKey: resumeKey(file))
    }
}

// MARK: - SMB (browse with AMSMB2, play with VLC's smb2 access)

final class SMBProvider: SourceProvider {
    let source: MediaSource
    private var manager: SMB2Manager?
    private var share: String?
    init(_ s: MediaSource) { source = s }

    private var hostOnly: String {
        var h = source.host.trimmed
        if h.lowercased().hasPrefix("smb://") { h = String(h.dropFirst(6)) }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }

    private func client() throws -> SMB2Manager {
        if let m = manager { return m }
        guard let url = URL(string: "smb://\(hostOnly)") else { throw AppError.message("SMB 地址无效") }
        let user = source.username.isEmpty ? "guest" : source.username
        let cred = URLCredential(user: user, password: source.password, persistence: .forSession)
        guard let m = SMB2Manager(url: url, domain: source.extra["domain"] ?? "", credential: cred) else { throw AppError.message("无法创建 SMB 连接") }
        manager = m
        return m
    }

    private func split(_ path: String) -> (String, String) {
        let comps = path.split(separator: "/").map(String.init)
        return (comps.first ?? "", comps.dropFirst().joined(separator: "/"))
    }

    private func connect(_ shareName: String) async throws -> SMB2Manager {
        let m = try client()
        if share != shareName {
            if share != nil { try? await m.disconnectShare() }
            try await m.connectShare(name: shareName)
            share = shareName
        }
        return m
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        guard let dir else {
            let m = try client()
            let shares = try await m.listShares()
            return shares.filter { !$0.name.hasSuffix("$") }.map {
                RemoteFile(id: "/" + $0.name, name: $0.name, path: "/" + $0.name, isDir: true, overview: $0.comment.isEmpty ? nil : $0.comment)
            }
        }
        let (shareName, sub) = split(dir.path)
        let m = try await connect(shareName)
        let items = try await m.contentsOfDirectory(atPath: sub)
        let files: [RemoteFile] = items.compactMap { d in
            guard let name = d[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
            let isDir = (d[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let size = (d[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            let p = dir.path + "/" + name
            return RemoteFile(id: p, name: name, path: p, isDir: isDir, size: size)
        }
        return Providers.sortFiles(files)
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        var auth = ""
        if !source.username.isEmpty {
            auth = source.username.userInfoEncoded + ":" + source.password.userInfoEncoded + "@"
        }
        let s = "smb://\(auth)\(hostOnly)\(file.path.urlPathEncoded)"
        guard let url = URL(string: s) else { throw AppError.message("SMB 路径无效") }
        return PlayableMedia(url: url, title: file.name, resumeKey: resumeKey(file))
    }

    func fetchData(_ file: RemoteFile) async throws -> Data {
        let (shareName, sub) = split(file.path)
        let m = try await connect(shareName)
        let d: Data = try await m.contents(atPath: sub, range: Range<UInt64>?.none, progress: nil)
        return d
    }
}

// MARK: - WebDAV

final class WebDAVProvider: SourceProvider {
    let source: MediaSource
    init(_ s: MediaSource) { source = s }

    private var base: URL? {
        var h = source.host.trimmed
        if !h.lowercased().hasPrefix("http") { h = "http://" + h }
        if !h.hasSuffix("/") { h += "/" }
        return URL(string: h)
    }
    private var origin: String {
        guard let b = base, let c = URLComponents(url: b, resolvingAgainstBaseURL: false) else { return "" }
        var s = "\(c.scheme ?? "http")://\(c.host ?? "")"
        if let p = c.port { s += ":\(p)" }
        return s
    }
    private var authHeader: [String: String] {
        guard !source.username.isEmpty else { return [:] }
        let t = Data("\(source.username):\(source.password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(t)"]
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        guard let base else { throw AppError.message("WebDAV 地址无效") }
        let path = dir?.path ?? base.path
        guard let url = URL(string: origin + (path.hasSuffix("/") ? path : path + "/").urlPathEncoded) else { throw AppError.message("路径无效") }
        var h = authHeader
        h["Depth"] = "1"
        h["Content-Type"] = "application/xml"
        let body = #"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"#
        let r = HTTP.request(url, method: "PROPFIND", headers: h, body: Data(body.utf8))
        let (d, resp) = try await HTTP.data(r)
        guard (200..<300).contains(resp.statusCode) else {
            throw AppError.message(resp.statusCode == 401 ? "WebDAV 认证失败" : "WebDAV 错误 HTTP \(resp.statusCode)")
        }
        let entries = DAVParser.parse(d)
        let selfPath = url.path.removingPercentEncoding ?? url.path
        let files: [RemoteFile] = entries.compactMap { e in
            var href = e.href
            if let u = URL(string: href), u.host != nil { href = u.path } // absolute href
            href = href.removingPercentEncoding ?? href
            let trimmedHref = href.hasSuffix("/") ? String(href.dropLast()) : href
            let trimmedSelf = selfPath.hasSuffix("/") ? String(selfPath.dropLast()) : selfPath
            if trimmedHref == trimmedSelf || trimmedHref.isEmpty { return nil }
            let name = e.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (trimmedHref as NSString).lastPathComponent
            if name.hasPrefix(".") { return nil }
            return RemoteFile(id: trimmedHref, name: name, path: trimmedHref, isDir: e.isCollection, size: e.length)
        }
        return Providers.sortFiles(files)
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        var s = origin
        if !source.username.isEmpty, let r = s.range(of: "://") {
            s.insert(contentsOf: source.username.userInfoEncoded + ":" + source.password.userInfoEncoded + "@", at: r.upperBound)
        }
        guard let url = URL(string: s + file.path.urlPathEncoded) else { throw AppError.message("路径无效") }
        return PlayableMedia(url: url, title: file.name, headers: authHeader, resumeKey: resumeKey(file))
    }
}

final class DAVParser: NSObject, XMLParserDelegate {
    struct Entry { var href = ""; var displayName: String?; var isCollection = false; var length: Int64 = 0 }
    private var entries: [Entry] = []
    private var cur: Entry?
    private var text = ""

    static func parse(_ d: Data) -> [Entry] {
        let p = XMLParser(data: d)
        let me = DAVParser()
        p.shouldProcessNamespaces = true
        p.delegate = me
        p.parse()
        return me.entries
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        let n = name.lowercased()
        if n == "response" { cur = Entry() }
        if n == "collection" { cur?.isCollection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name.lowercased() {
        case "href": cur?.href = text.trimmed
        case "displayname": cur?.displayName = text.trimmed
        case "getcontentlength": cur?.length = Int64(text.trimmed) ?? 0
        case "response": if let c = cur { entries.append(c) }; cur = nil
        default: break
        }
    }
}

// MARK: - Emby / Jellyfin

final class EmbyProvider: SourceProvider {
    private(set) var source: MediaSource
    init(_ s: MediaSource) { source = s }

    static var deviceId: String {
        if let d = UserDefaults.standard.string(forKey: "deviceId") { return d }
        let d = UUID().uuidString
        UserDefaults.standard.set(d, forKey: "deviceId")
        return d
    }
    private var base: String {
        var h = source.host.trimmed
        if !h.lowercased().hasPrefix("http") { h = "http://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }
    private var authValue: String {
        var v = #"MediaBrowser Client="HarkPlayer", Device="iOS", DeviceId="\#(Self.deviceId)", Version="1.0.0""#
        if !source.token.isEmpty { v += #", Token="\#(source.token)""# }
        return v
    }
    private var headers: [String: String] {
        var h = ["X-Emby-Authorization": authValue, "Authorization": authValue, "Accept": "application/json"]
        if !source.token.isEmpty { h["X-Emby-Token"] = source.token; h["X-MediaBrowser-Token"] = source.token }
        return h
    }

    /// Returns updated source with token + userId.
    static func login(_ s: MediaSource) async throws -> MediaSource {
        var s = s
        s.token = ""
        let p = EmbyProvider(s)
        guard let url = URL(string: p.base + "/Users/AuthenticateByName") else { throw AppError.message("服务器地址无效") }
        let r = HTTP.request(url, method: "POST", headers: p.headers, json: ["Username": s.username, "Pw": s.password, "Password": s.password])
        let o = try await HTTP.json(r)
        guard let token = o.str("AccessToken"), let uid = o.dict("User")?.str("Id") else { throw AppError.message("登录失败") }
        s.token = token
        s.userId = uid
        return s
    }

    private func get(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw AppError.message("地址无效") }
        return try await HTTP.json(HTTP.request(url, headers: headers))
    }

    private func image(_ id: String, tag: String?, type: String = "Primary") -> URL? {
        var s = "\(base)/Items/\(id)/Images/\(type)?maxHeight=600&quality=90&api_key=\(source.token)"
        if let tag { s += "&tag=\(tag)" }
        return URL(string: s)
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        if source.token.isEmpty { source = try await EmbyProvider.login(source); await SourceStore.shared.updateCredentials(source) }
        let o: [String: Any]
        if let dir {
            o = try await get("/Users/\(source.userId)/Items?ParentId=\(dir.id)&Fields=Overview,ProductionYear,MediaSources,Path&SortBy=SortName&SortOrder=Ascending&EnableImageTypes=Primary,Backdrop")
        } else {
            o = try await get("/Users/\(source.userId)/Views")
        }
        return o.arr("Items").map { it in
            let id = it.str("Id") ?? ""
            let type = it.str("Type") ?? ""
            let isFolder = (it["IsFolder"] as? Bool) ?? false
            var f = RemoteFile(id: id, name: it.str("Name") ?? "未命名", path: id, isDir: isFolder, size: 0)
            let tag = it.dict("ImageTags")?.str("Primary")
            f.posterURL = image(id, tag: tag)
            f.overview = it.str("Overview")
            f.year = it.int("ProductionYear")
            f.meta["type"] = isFolder ? "Folder:" + type : type
            if let s = it.int("ParentIndexNumber") { f.meta["season"] = String(s) }
            if let e = it.int("IndexNumber") { f.meta["episode"] = String(e) }
            if let series = it.str("SeriesName") { f.meta["series"] = series }
            if let ticks = it.int64("RunTimeTicks") { f.meta["runtime"] = String(ticks / 10_000_000) }
            if let path = it.str("Path") { f.meta["filePath"] = path }
            return f
        }
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        if source.token.isEmpty { source = try await EmbyProvider.login(source); await SourceStore.shared.updateCredentials(source) }
        guard let url = URL(string: "\(base)/Videos/\(file.id)/stream?static=true&MediaSourceId=\(file.id)&api_key=\(source.token)&DeviceId=\(Self.deviceId)") else { throw AppError.message("地址无效") }
        var p = PlayableMedia(url: url, title: file.name, resumeKey: resumeKey(file))
        // external subtitle streams known to the server
        if let item = try? await get("/Users/\(source.userId)/Items/\(file.id)"),
           let ms = item.arr("MediaSources").first {
            let msid = ms.str("Id") ?? file.id
            for st in ms.arr("MediaStreams") where st.str("Type") == "Subtitle" && (st["IsExternal"] as? Bool) == true {
                guard let idx = st.int("Index") else { continue }
                var codec = (st.str("Codec") ?? "srt").lowercased()
                if codec == "subrip" { codec = "srt" }
                let path = source.kind == .jellyfin
                    ? "/Videos/\(file.id)/\(msid)/Subtitles/\(idx)/0/Stream.\(codec)"
                    : "/Videos/\(file.id)/\(msid)/Subtitles/\(idx)/Stream.\(codec)"
                if let u = URL(string: base + path + "?api_key=\(source.token)") { p.subtitleFiles.append(u) }
            }
        }
        return p
    }
}

// MARK: - 阿里云盘 (Open Platform API: needs the user's own client_id/secret, or an alist-style refresh proxy)

final class AliyunProvider: SourceProvider {
    private(set) var source: MediaSource
    static let api = "https://openapi.alipan.com"
    init(_ s: MediaSource) { source = s }

    private var clientId: String { source.extra["clientId"] ?? "" }
    private var clientSecret: String { source.extra["clientSecret"] ?? "" }

    // QR login
    static func startQR(clientId: String, clientSecret: String) async throws -> (qrURL: String, sid: String) {
        let r = HTTP.request(URL(string: api + "/oauth/authorize/qrcode")!, method: "POST",
                             json: ["client_id": clientId, "client_secret": clientSecret,
                                    "scopes": ["user:base", "file:all:read"], "width": 430, "height": 430])
        let o = try await HTTP.json(r)
        guard let u = o.str("qrCodeUrl"), let sid = o.str("sid") else { throw AppError.message("获取二维码失败") }
        return (u, sid)
    }
    /// returns authCode when confirmed
    static func pollQR(sid: String) async throws -> (status: String, authCode: String?) {
        let o = try await HTTP.json(HTTP.request(URL(string: api + "/oauth/qrcode/\(sid)/status")!))
        return (o.str("status") ?? "", o.str("authCode"))
    }
    static func exchange(_ s: MediaSource, code: String) async throws -> MediaSource {
        var s = s
        let o = try await HTTP.json(HTTP.request(URL(string: api + "/oauth/access_token")!, method: "POST",
            json: ["client_id": s.extra["clientId"] ?? "", "client_secret": s.extra["clientSecret"] ?? "", "grant_type": "authorization_code", "code": code]))
        s.token = o.str("access_token") ?? ""
        s.refreshToken = o.str("refresh_token") ?? ""
        s.tokenExpiry = Date().addingTimeInterval(Double(o.int("expires_in") ?? 7000) - 120)
        if s.token.isEmpty { throw AppError.message("换取令牌失败") }
        return s
    }

    private func refreshIfNeeded() async throws {
        if !source.token.isEmpty, let e = source.tokenExpiry, e > Date() { return }
        guard !source.refreshToken.isEmpty else { throw AppError.message("请先扫码登录阿里云盘") }
        let o: [String: Any]
        if let proxy = source.extra["refreshURL"], !proxy.isEmpty, let u = URL(string: proxy) {
            o = try await HTTP.json(HTTP.request(u, method: "POST", json: ["refresh_token": source.refreshToken, "grant_type": "refresh_token"]))
        } else {
            o = try await HTTP.json(HTTP.request(URL(string: Self.api + "/oauth/access_token")!, method: "POST",
                json: ["client_id": clientId, "client_secret": clientSecret, "grant_type": "refresh_token", "refresh_token": source.refreshToken]))
        }
        guard let at = o.str("access_token") else { throw AppError.message("阿里云盘令牌刷新失败，请重新登录") }
        source.token = at
        if let rt = o.str("refresh_token") { source.refreshToken = rt }
        source.tokenExpiry = Date().addingTimeInterval(Double(o.int("expires_in") ?? 7000) - 120)
        await SourceStore.shared.updateCredentials(source)
    }

    private func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await refreshIfNeeded()
        let r = HTTP.request(URL(string: Self.api + path)!, method: "POST", headers: ["Authorization": "Bearer \(source.token)"], json: body)
        return try await HTTP.json(r)
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        guard let dir else {
            let info = try await call("/adrive/v1.0/user/getDriveInfo", [:])
            var roots: [RemoteFile] = []
            if let d = info.str("backup_drive_id") ?? info.str("default_drive_id") {
                roots.append(RemoteFile(id: "\(d):root", name: "备份盘", path: "root", isDir: true, meta: ["drive": d]))
            }
            if let d = info.str("resource_drive_id") {
                roots.append(RemoteFile(id: "\(d):root", name: "资源库", path: "root", isDir: true, meta: ["drive": d]))
            }
            return roots
        }
        let drive = dir.meta["drive"] ?? ""
        var out: [RemoteFile] = []
        var marker = ""
        repeat {
            var body: [String: Any] = ["drive_id": drive, "parent_file_id": dir.path, "limit": 100, "order_by": "name", "order_direction": "ASC"]
            if !marker.isEmpty { body["marker"] = marker }
            let o = try await call("/adrive/v1.0/openFile/list", body)
            for it in o.arr("items") {
                let fid = it.str("file_id") ?? ""
                var f = RemoteFile(id: "\(drive):\(fid)", name: it.str("name") ?? "", path: fid, isDir: it.str("type") == "folder", size: it.int64("size") ?? 0)
                f.meta["drive"] = drive
                if let t = it.str("thumbnail"), let u = URL(string: t) { f.posterURL = u }
                out.append(f)
            }
            marker = o.str("next_marker") ?? ""
        } while !marker.isEmpty && out.count < 50000
        return Providers.sortFiles(out)
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        let o = try await call("/adrive/v1.0/openFile/getDownloadUrl", ["drive_id": file.meta["drive"] ?? "", "file_id": file.path, "expire_sec": 14400])
        guard let s = o.str("url"), let u = URL(string: s) else { throw AppError.message("获取播放地址失败") }
        return PlayableMedia(url: u, title: file.name, headers: ["Referer": "https://www.alipan.com/"], resumeKey: resumeKey(file))
    }
}

// MARK: - 115 (unofficial web API, QR login via 115 app; experimental)

final class Pan115Provider: SourceProvider {
    private(set) var source: MediaSource
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 115Browser/27.0.5.7"
    init(_ s: MediaSource) { source = s }
    private var cookie: String { source.extra["cookie"] ?? "" }
    private var headers: [String: String] { ["Cookie": cookie, "User-Agent": Self.ua, "Referer": "https://115.com/"] }

    static func startQR() async throws -> (uid: String, time: String, sign: String, qr: String) {
        let o = try await HTTP.json(HTTP.request(URL(string: "https://qrcodeapi.115.com/api/1.0/web/1.0/token/")!, headers: ["User-Agent": ua]))
        guard let d = o.dict("data"), let uid = d.str("uid"), let t = d.str("time"), let sign = d.str("sign") else { throw AppError.message("获取 115 二维码失败") }
        return (uid, t, sign, d.str("qrcode") ?? "https://115.com/scan/dg-\(uid)")
    }
    /// 0 等待, 1 已扫码, 2 已确认, -1 过期, -2 取消
    static func pollQR(uid: String, time: String, sign: String) async throws -> Int {
        let u = URL(string: "https://qrcodeapi.115.com/get/status/?uid=\(uid)&time=\(time)&sign=\(sign)&_=\(Int(Date().timeIntervalSince1970))")!
        var r = HTTP.request(u, headers: ["User-Agent": ua])
        r.timeoutInterval = 40
        let o = try await HTTP.json(r)
        return o.dict("data")?.int("status") ?? 0
    }
    static func finishQR(uid: String, app: String = "alipaymini") async throws -> String {
        let r = HTTP.request(URL(string: "https://passportapi.115.com/app/1.0/\(app)/1.0/login/qrcode/")!, method: "POST",
                             headers: ["User-Agent": ua], form: ["account": uid, "app": app])
        let o = try await HTTP.json(r)
        guard let c = o.dict("data")?.dict("cookie") else { throw AppError.message((o.str("message") ?? o.str("error")) ?? "115 登录失败") }
        return c.map { "\($0.key)=\(($0.value as? String) ?? "")" }.joined(separator: "; ")
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        guard !cookie.isEmpty else { throw AppError.message("请先扫码登录 115") }
        let cid = dir?.path ?? "0"
        var out: [RemoteFile] = []
        var offset = 0
        while true {
            let u = URL(string: "https://webapi.115.com/files?aid=1&cid=\(cid)&o=file_name&asc=1&offset=\(offset)&show_dir=1&limit=1000&snap=0&natsort=1&record_open_time=1&format=json")!
            let o = try await HTTP.json(HTTP.request(u, headers: headers))
            if let st = o["state"] as? Bool, !st { throw AppError.message(o.str("error") ?? "115 请求失败，cookie 可能已失效") }
            let data = o.arr("data")
            for it in data {
                let isDir = it["fid"] == nil
                let name = it.str("n") ?? ""
                if isDir {
                    let id = it.str("cid") ?? ""
                    out.append(RemoteFile(id: id, name: name, path: id, isDir: true))
                } else {
                    let fid = it.str("fid") ?? ""
                    var f = RemoteFile(id: fid, name: name, path: fid, isDir: false, size: it.int64("s") ?? 0)
                    f.meta["pickcode"] = it.str("pc") ?? ""
                    if let t = it.str("u"), let tu = URL(string: t) { f.posterURL = tu }
                    out.append(f)
                }
            }
            let count = o.int("count") ?? 0
            offset += data.count
            if data.isEmpty || offset >= count || offset > 50000 { break }
        }
        return Providers.sortFiles(out)
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        let pc = file.meta["pickcode"] ?? ""
        let u = URL(string: "https://webapi.115.com/files/download?pickcode=\(pc)&_=\(Int(Date().timeIntervalSince1970))")!
        let o = try await HTTP.json(HTTP.request(u, headers: headers))
        guard let s = o.str("file_url"), let url = URL(string: s) else {
            throw AppError.message(o.str("msg") ?? o.str("error") ?? "115 获取下载地址失败（该接口为非官方接口，可能已被限制）")
        }
        return PlayableMedia(url: url, title: file.name, headers: ["User-Agent": Self.ua, "Cookie": cookie, "Referer": "https://115.com/"], resumeKey: resumeKey(file))
    }
}

// MARK: - 百度网盘 (xpan open API; needs the user's own AppKey/SecretKey)

final class BaiduProvider: SourceProvider {
    private(set) var source: MediaSource
    init(_ s: MediaSource) { source = s }
    static let ua = "pan.baidu.com"

    struct DeviceCode { var deviceCode: String; var userCode: String; var verifyURL: String; var qrURL: String; var interval: Int }
    static func startDevice(appKey: String) async throws -> DeviceCode {
        let u = URL(string: "https://openapi.baidu.com/oauth/2.0/device/code?response_type=device_code&client_id=\(appKey)&scope=basic,netdisk")!
        let o = try await HTTP.json(HTTP.request(u))
        guard let dc = o.str("device_code") else { throw AppError.message(o.str("error_description") ?? "获取授权码失败") }
        return DeviceCode(deviceCode: dc, userCode: o.str("user_code") ?? "", verifyURL: o.str("verification_url") ?? "https://openapi.baidu.com/device",
                          qrURL: o.str("qrcode_url") ?? "", interval: o.int("interval") ?? 5)
    }
    /// nil while pending
    static func pollDevice(_ s: MediaSource, code: String) async throws -> MediaSource? {
        let u = URL(string: "https://openapi.baidu.com/oauth/2.0/token?grant_type=device_token&code=\(code)&client_id=\(s.extra["appKey"] ?? "")&client_secret=\(s.extra["secretKey"] ?? "")")!
        let (d, _) = try await HTTP.data(HTTP.request(u))
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        if let at = o.str("access_token") {
            var s = s
            s.token = at
            s.refreshToken = o.str("refresh_token") ?? ""
            s.tokenExpiry = Date().addingTimeInterval(Double(o.int("expires_in") ?? 2_592_000) - 600)
            return s
        }
        let err = o.str("error") ?? ""
        if err == "authorization_pending" || err == "slow_down" { return nil }
        throw AppError.message(o.str("error_description") ?? "授权失败")
    }

    private func refreshIfNeeded() async throws {
        if !source.token.isEmpty, let e = source.tokenExpiry, e > Date() { return }
        guard !source.refreshToken.isEmpty else { throw AppError.message("请先登录百度网盘") }
        let u = URL(string: "https://openapi.baidu.com/oauth/2.0/token?grant_type=refresh_token&refresh_token=\(source.refreshToken)&client_id=\(source.extra["appKey"] ?? "")&client_secret=\(source.extra["secretKey"] ?? "")")!
        let o = try await HTTP.json(HTTP.request(u))
        guard let at = o.str("access_token") else { throw AppError.message("百度令牌刷新失败，请重新登录") }
        source.token = at
        source.refreshToken = o.str("refresh_token") ?? source.refreshToken
        source.tokenExpiry = Date().addingTimeInterval(Double(o.int("expires_in") ?? 2_592_000) - 600)
        await SourceStore.shared.updateCredentials(source)
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        try await refreshIfNeeded()
        let path = dir?.path ?? "/"
        var out: [RemoteFile] = []
        var start = 0
        while true {
            let u = URL(string: "https://pan.baidu.com/rest/2.0/xpan/file?method=list&dir=\(path.urlQueryEncoded)&order=name&start=\(start)&limit=1000&web=1&access_token=\(source.token)")!
            let o = try await HTTP.json(HTTP.request(u, headers: ["User-Agent": Self.ua]))
            if let errno = o.int("errno"), errno != 0 { throw AppError.message("百度网盘错误 \(errno)") }
            let list = o.arr("list")
            for it in list {
                var f = RemoteFile(id: it.str("fs_id") ?? "", name: it.str("server_filename") ?? "", path: it.str("path") ?? "",
                                   isDir: it.int("isdir") == 1, size: it.int64("size") ?? 0)
                f.meta["fsid"] = it.str("fs_id") ?? ""
                if let th = it.dict("thumbs")?.str("url3"), let tu = URL(string: th) { f.posterURL = tu }
                out.append(f)
            }
            if list.count < 1000 { break }
            start += 1000
        }
        return Providers.sortFiles(out)
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        try await refreshIfNeeded()
        let u = URL(string: "https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&fsids=%5B\(file.meta["fsid"] ?? file.id)%5D&dlink=1&access_token=\(source.token)")!
        let o = try await HTTP.json(HTTP.request(u, headers: ["User-Agent": Self.ua]))
        guard let dl = o.arr("list").first?.str("dlink"), let url = URL(string: dl + "&access_token=\(source.token)") else {
            throw AppError.message("获取百度网盘播放地址失败")
        }
        return PlayableMedia(url: url, title: file.name, headers: ["User-Agent": Self.ua], resumeKey: resumeKey(file))
    }
}
