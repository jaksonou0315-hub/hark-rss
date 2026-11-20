import Foundation
import SwiftUI
import WebKit

// MARK: - Shared helpers

enum NoRedirect {
    final class Delegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpCookieStorage = nil
        return URLSession(configuration: c, delegate: Delegate(), delegateQueue: nil)
    }()
    /// Returns the Location header of a 30x, or nil.
    static func location(_ r: URLRequest) async throws -> (URL?, Data, Int) {
        let (d, resp) = try await session.data(for: r)
        let h = resp as? HTTPURLResponse
        let loc = (h?.value(forHTTPHeaderField: "Location")).flatMap { URL(string: $0) }
        return (loc, d, h?.statusCode ?? 0)
    }
}

extension Dictionary where Key == String, Value == Any {
    func bool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.boolValue }
        return nil
    }
}

// MARK: - OpenList token service (api.oplist.org): OAuth for OneDrive / Dropbox / Yandex.Disk without own developer apps

enum OpListAuth {
    static let base = "https://api.oplist.org"

    struct Spec { var driver: String; var type: String }
    static func spec(_ k: SourceKind) -> Spec? {
        switch k {
        case .onedrive: return Spec(driver: "onedrive", type: "onedrive_pr")
        case .dropbox: return Spec(driver: "dropboxs", type: "dropboxs_go")
        case .yandex: return Spec(driver: "yandexui", type: "yandexui_go")
        default: return nil
        }
    }

    static func loginURL(_ k: SourceKind) async throws -> URL {
        guard let s = spec(k) else { throw AppError.message("不支持") }
        var c = URLComponents(string: "\(base)/\(s.driver)/requests")!
        c.queryItems = [.init(name: "server_use", value: "true"), .init(name: "server_set", value: "true"),
                        .init(name: "driver_txt", value: s.type), .init(name: "apps_types", value: s.type),
                        .init(name: "client_uid", value: ""), .init(name: "client_key", value: "")]
        let o = try await HTTP.json(HTTP.request(c.url!))
        guard let t = o.str("text"), let u = URL(string: t), u.scheme?.hasPrefix("http") == true else {
            throw AppError.message(o.str("message_err") ?? o.str("text") ?? "获取登录地址失败")
        }
        return u
    }

    /// The callback page lands on  https://api.oplist.org/#<base64 json>
    static func parseCallback(_ url: URL) -> (access: String, refresh: String)? {
        guard url.host?.contains("oplist") == true else { return nil }
        let candidates = [url.fragment, URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "data" }?.value]
        for c in candidates.compactMap({ $0 }) where !c.isEmpty {
            var s = c.removingPercentEncoding ?? c
            if s.hasPrefix("/") { s.removeFirst() }
            s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while s.count % 4 != 0 { s += "=" }
            guard let d = Data(base64Encoded: s), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let rt = o.str("refresh_token") ?? ""
            if !rt.isEmpty { return (o.str("access_token") ?? "", rt) }
        }
        return nil
    }

    static func renew(_ k: SourceKind, refresh: String) async throws -> (access: String, refresh: String, expires: Int) {
        guard let s = spec(k) else { throw AppError.message("不支持") }
        var c = URLComponents(string: "\(base)/\(s.driver)/renewapi")!
        c.queryItems = [.init(name: "refresh_ui", value: refresh), .init(name: "server_use", value: "true"),
                        .init(name: "driver_txt", value: s.type), .init(name: "apps_types", value: s.type)]
        let o = try await HTTP.json(HTTP.request(c.url!))
        guard let at = o.str("access_token"), !at.isEmpty else {
            throw AppError.message("登录已过期，请重新登录（\(o.str("text") ?? o.str("message_err") ?? "刷新失败")）")
        }
        return (at, o.str("refresh_token").flatMap { $0.isEmpty ? nil : $0 } ?? refresh, o.int("expires_in") ?? 3600)
    }
}

/// Base for token-based drives: refreshes the access token via a closure and retries once on 401.
class TokenDrive {
    var source: MediaSource
    init(_ s: MediaSource) { source = s }

    func refreshToken() async throws {
        let r = try await OpListAuth.renew(source.kind, refresh: source.refreshToken.trimmed)
        source.token = r.access
        source.refreshToken = r.refresh
        source.tokenExpiry = Date().addingTimeInterval(Double(r.expires) - 300)
        await SourceStore.shared.updateCredentials(source)
    }

    var authHeader: String { "Bearer \(source.token)" }

    func call(_ build: () -> URLRequest) async throws -> [String: Any] {
        if source.refreshToken.trimmed.isEmpty && source.token.isEmpty { throw AppError.message("\(source.kind.title)：请先登录") }
        if source.token.isEmpty || (source.tokenExpiry.map { $0 < Date() } ?? false) { try await refreshToken() }
        func once() async throws -> (Int, [String: Any], Data) {
            var r = build()
            r.setValue(authHeader, forHTTPHeaderField: "Authorization")
            let (d, h) = try await HTTP.data(r)
            return (h.statusCode, ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:], d)
        }
        var (st, o, d) = try await once()
        if st == 401 {
            try await refreshToken()
            (st, o, d) = try await once()
        }
        guard (200..<300).contains(st) else {
            let e = (o["error"] as? [String: Any])?.str("message") ?? o.str("error_summary") ?? o.str("message") ?? o.str("description")
                ?? String(data: d.prefix(160), encoding: .utf8) ?? ""
            throw AppError.message("\(source.kind.title) HTTP \(st)：\(e)")
        }
        return o
    }
}

// MARK: - OneDrive (Microsoft Graph)

final class OneDriveProvider: TokenDrive, SourceProvider {
    static let graph = "https://graph.microsoft.com/v1.0/me/drive"
    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        var next: String? = (dir.map { "\(Self.graph)/items/\($0.id)/children" } ?? "\(Self.graph)/root/children")
            + "?$top=1000&$select=id,name,size,folder,file"
        var out: [RemoteFile] = []
        while let n = next, let u = URL(string: n), out.count < 50000 {
            let o = try await call { HTTP.request(u) }
            for it in o.arr("value") {
                let id = it.str("id") ?? ""
                out.append(RemoteFile(id: id, name: it.str("name") ?? "", path: id, isDir: it["folder"] != nil, size: it.int64("size") ?? 0))
            }
            next = o.str("@odata.nextLink")
        }
        return Providers.sortFiles(out)
    }
    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        let o = try await call { HTTP.request(URL(string: "\(Self.graph)/items/\(file.id)?select=id,@microsoft.graph.downloadUrl")!) }
        guard let s = o.str("@microsoft.graph.downloadUrl"), let u = URL(string: s) else { throw AppError.message("OneDrive：获取播放地址失败") }
        return PlayableMedia(url: u, title: file.name, resumeKey: resumeKey(file))
    }
}

// MARK: - Dropbox

final class DropboxProvider: TokenDrive, SourceProvider {
    static let api = "https://api.dropboxapi.com/2"
    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        var out: [RemoteFile] = []
        var o = try await call { HTTP.request(URL(string: Self.api + "/files/list_folder")!, method: "POST",
                                              json: ["path": dir?.path ?? "", "limit": 2000, "include_media_info": false]) }
        while true {
            for it in o.arr("entries") {
                let path = it.str("path_lower") ?? it.str("path_display") ?? ""
                out.append(RemoteFile(id: it.str("id") ?? path, name: it.str("name") ?? "", path: path,
                                      isDir: it.str(".tag") == "folder", size: it.int64("size") ?? 0))
            }
            guard o.bool("has_more") == true, let cur = o.str("cursor"), out.count < 50000 else { break }
            o = try await call { HTTP.request(URL(string: Self.api + "/files/list_folder/continue")!, method: "POST", json: ["cursor": cur]) }
        }
        return Providers.sortFiles(out)
    }
    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        let o = try await call { HTTP.request(URL(string: Self.api + "/files/get_temporary_link")!, method: "POST", json: ["path": file.path]) }
        guard let s = o.str("link"), let u = URL(string: s) else { throw AppError.message("Dropbox：获取播放地址失败") }
        return PlayableMedia(url: u, title: file.name, resumeKey: resumeKey(file))
    }
}

// MARK: - Yandex.Disk

final class YandexProvider: TokenDrive, SourceProvider {
    static let api = "https://cloud-api.yandex.net/v1/disk"
    override var authHeader: String { "OAuth \(source.token)" }
    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        var out: [RemoteFile] = []
        var offset = 0
        let path = dir?.path ?? "disk:/"
        while out.count < 50000 {
            var c = URLComponents(string: Self.api + "/resources")!
            c.queryItems = [.init(name: "path", value: path), .init(name: "limit", value: "500"), .init(name: "offset", value: String(offset)),
                            .init(name: "fields", value: "_embedded.items.name,_embedded.items.path,_embedded.items.type,_embedded.items.size,_embedded.items.resource_id,_embedded.total")]
            let o = try await call { HTTP.request(c.url!) }
            let emb = o.dict("_embedded") ?? [:]
            let items = emb.arr("items")
            for it in items {
                let p = it.str("path") ?? ""
                out.append(RemoteFile(id: it.str("resource_id") ?? p, name: it.str("name") ?? "", path: p, isDir: it.str("type") == "dir", size: it.int64("size") ?? 0))
            }
            offset += items.count
            if items.count < 500 || offset >= (emb.int("total") ?? 0) { break }
        }
        return Providers.sortFiles(out)
    }
    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        var c = URLComponents(string: Self.api + "/resources/download")!
        c.queryItems = [.init(name: "path", value: file.path)]
        let o = try await call { HTTP.request(c.url!) }
        guard let s = o.str("href"), let u = URL(string: s) else { throw AppError.message("Yandex：获取播放地址失败") }
        return PlayableMedia(url: u, title: file.name, resumeKey: resumeKey(file))
    }
}

// MARK: - Box (own developer app: client_id / client_secret, redirect http://localhost)

final class BoxProvider: TokenDrive, SourceProvider {
    static let api = "https://api.box.com/2.0"
    static let redirect = "http://localhost"

    static func authorizeURL(_ s: MediaSource) -> URL? {
        var c = URLComponents(string: "https://account.box.com/api/oauth2/authorize")!
        c.queryItems = [.init(name: "response_type", value: "code"), .init(name: "client_id", value: (s.extra["clientId"] ?? "").trimmed),
                        .init(name: "redirect_uri", value: redirect)]
        return c.url
    }
    static func token(_ s: MediaSource, code: String? = nil) async throws -> MediaSource {
        var form = ["client_id": (s.extra["clientId"] ?? "").trimmed, "client_secret": (s.extra["clientSecret"] ?? "").trimmed]
        if let code { form["grant_type"] = "authorization_code"; form["code"] = code } else {
            form["grant_type"] = "refresh_token"; form["refresh_token"] = s.refreshToken.trimmed
        }
        let o = try await HTTP.json(HTTP.request(URL(string: "https://api.box.com/oauth2/token")!, method: "POST", form: form))
        guard let at = o.str("access_token") else { throw AppError.message(o.str("error_description") ?? "Box 登录失败") }
        var s = s
        s.token = at
        s.refreshToken = o.str("refresh_token") ?? s.refreshToken
        s.tokenExpiry = Date().addingTimeInterval(Double(o.int("expires_in") ?? 3600) - 300)
        return s
    }
    override func refreshToken() async throws {
        source = try await Self.token(source)
        await SourceStore.shared.updateCredentials(source)
    }
    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        var out: [RemoteFile] = []
        var offset = 0
        while out.count < 50000 {
            let u = URL(string: "\(Self.api)/folders/\(dir?.id ?? "0")/items?fields=id,type,name,size&limit=1000&offset=\(offset)")!
            let o = try await call { HTTP.request(u) }
            let es = o.arr("entries")
            for it in es {
                let id = it.str("id") ?? ""
                out.append(RemoteFile(id: id, name: it.str("name") ?? "", path: id, isDir: it.str("type") == "folder", size: it.int64("size") ?? 0))
            }
            offset += es.count
            if es.isEmpty || offset >= (o.int("total_count") ?? 0) { break }
        }
        return Providers.sortFiles(out)
    }
    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        if source.token.isEmpty || (source.tokenExpiry.map { $0 < Date() } ?? false) { try await refreshToken() }
        var r = HTTP.request(URL(string: "\(Self.api)/files/\(file.id)/content")!)
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        var (loc, _, st) = try await NoRedirect.location(r)
        if st == 401 {
            try await refreshToken()
            r.setValue(authHeader, forHTTPHeaderField: "Authorization")
            (loc, _, st) = try await NoRedirect.location(r)
        }
        guard let loc else { throw AppError.message("Box：获取播放地址失败（HTTP \(st)）") }
        return PlayableMedia(url: loc, title: file.name, resumeKey: resumeKey(file))
    }
}

// MARK: - pCloud (username / password)

final class PCloudProvider: SourceProvider {
    private(set) var source: MediaSource
    init(_ s: MediaSource) { source = s }

    static func host(_ s: MediaSource) -> String { s.extra["region"] == "eu" ? "https://eapi.pcloud.com" : "https://api.pcloud.com" }

    static func login(_ s: MediaSource) async throws -> MediaSource {
        var s = s
        for region in [s.extra["region"] ?? "us", s.extra["region"] == "eu" ? "us" : "eu"] {
            s.extra["region"] = region
            var c = URLComponents(string: host(s) + "/userinfo")!
            c.queryItems = [.init(name: "getauth", value: "1"), .init(name: "logout", value: "1"),
                            .init(name: "username", value: s.username.trimmed), .init(name: "password", value: s.password)]
            let o = try await HTTP.json(HTTP.request(c.url!))
            let r = o.int("result") ?? -1
            if r == 0, let a = o.str("auth") { s.token = a; return s }
            if r == 2321 { continue }   // account lives in the other region
            throw AppError.message("pCloud 登录失败：\(o.str("error") ?? "错误 \(r)")")
        }
        throw AppError.message("pCloud 登录失败")
    }

    private func call(_ method: String, _ q: [String: String]) async throws -> [String: Any] {
        if source.token.isEmpty { source = try await Self.login(source); await SourceStore.shared.updateCredentials(source) }
        func once() async throws -> [String: Any] {
            var c = URLComponents(string: Self.host(source) + "/" + method)!
            c.queryItems = (q.map { URLQueryItem(name: $0.key, value: $0.value) }) + [.init(name: "auth", value: source.token)]
            return try await HTTP.json(HTTP.request(c.url!))
        }
        var o = try await once()
        if [1000, 2000, 2094].contains(o.int("result") ?? 0) {
            source = try await Self.login(source)
            await SourceStore.shared.updateCredentials(source)
            o = try await once()
        }
        if let r = o.int("result"), r != 0 { throw AppError.message("pCloud：\(o.str("error") ?? "错误 \(r)")") }
        return o
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        let o = try await call("listfolder", ["folderid": dir?.id ?? "0"])
        let items = (o.dict("metadata") ?? [:]).arr("contents")
        return Providers.sortFiles(items.map { it in
            let folder = it.bool("isfolder") == true
            let id = folder ? String(it.int64("folderid") ?? 0) : String(it.int64("fileid") ?? 0)
            return RemoteFile(id: id, name: it.str("name") ?? "", path: id, isDir: folder, size: it.int64("size") ?? 0)
        })
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        let o = try await call("getfilelink", ["fileid": file.id, "forcedownload": "1"])
        guard let h = (o["hosts"] as? [String])?.first, let p = o.str("path"), let u = URL(string: "https://\(h)\(p)") else {
            throw AppError.message("pCloud：获取播放地址失败")
        }
        return PlayableMedia(url: u, title: file.name, resumeKey: resumeKey(file))
    }
}

// MARK: - 123 云盘 (account / password, web API — same as OpenList's 123 driver)

final class Pan123Provider: SourceProvider {
    private(set) var source: MediaSource
    init(_ s: MediaSource) { source = s }

    static let main = "https://yun.123pan.com/b/api"
    static let signIn = "https://login.123pan.com/api/user/sign_in"

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private static func crc(_ s: String) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in s.utf8 { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
    private static func signed(_ raw: String) -> URL {
        var c = URLComponents(string: raw)!
        let table: [Character] = ["a", "d", "e", "f", "g", "h", "l", "m", "y", "i", "j", "n", "o", "p", "k", "q", "r", "s", "t", "u", "b", "c", "v", "w", "s", "z"]
        let random = String(Int((Double.random(in: 0..<1) * 1e7).rounded()))
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let p = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let nowStr = String(format: "%04d%02d%02d%02d%02d", p.year!, p.month!, p.day!, p.hour!, p.minute!)
        let mapped = String(nowStr.map { table[Int($0.asciiValue! - 48)] })
        let timeSign = String(crc(mapped))
        let ts = String(Int(now.timeIntervalSince1970))
        let data = [ts, random, c.path, "web", "3", timeSign].joined(separator: "|")
        let dataSign = String(crc(data))
        c.queryItems = (c.queryItems ?? []) + [.init(name: timeSign, value: "\(ts)-\(random)-\(dataSign)")]
        return c.url!
    }
    private static let headers = ["origin": "https://yun.123pan.com", "referer": "https://yun.123pan.com/", "platform": "web", "app-version": "3"]

    static func login(_ s: MediaSource) async throws -> MediaSource {
        let user = s.username.trimmed
        let body: [String: Any] = user.contains("@") ? ["mail": user, "password": s.password, "type": 2]
                                                    : ["passport": user, "password": s.password, "remember": true]
        var h = headers
        h["user-agent"] = "Dart/2.19(dart:io)-openlist"
        let o = try await HTTP.json(HTTP.request(URL(string: signIn)!, method: "POST", headers: h, json: body))
        guard o.int("code") == 200, let t = o.dict("data")?.str("token"), !t.isEmpty else {
            throw AppError.message("123 云盘登录失败：\(o.str("message") ?? "账号或密码错误")")
        }
        var s = s
        s.token = t
        return s
    }

    private func request(_ path: String, method: String = "GET", query: [String: String] = [:], json: [String: Any]? = nil) async throws -> [String: Any] {
        if source.token.isEmpty { source = try await Self.login(source); await SourceStore.shared.updateCredentials(source) }
        func once() async throws -> [String: Any] {
            var c = URLComponents(string: Self.main + path)!
            if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
            var h = Self.headers
            h["authorization"] = "Bearer \(source.token)"
            h["user-agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) openlist-client"
            return try await HTTP.json(HTTP.request(Self.signed(c.url!.absoluteString), method: method, headers: h, json: json))
        }
        var o = try await once()
        if o.int("code") == 401 {
            source = try await Self.login(source)
            await SourceStore.shared.updateCredentials(source)
            o = try await once()
        }
        if let c = o.int("code"), c != 0 { throw AppError.message("123 云盘：\(o.str("message") ?? "错误 \(c)")") }
        return o
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        var out: [RemoteFile] = []
        var page = 1
        while page < 300 {
            let o = try await request("/file/list/new", query: [
                "driveId": "0", "limit": "100", "next": "0", "orderBy": "file_id", "orderDirection": "desc",
                "parentFileId": dir?.id ?? "0", "trashed": "false", "SearchData": "", "Page": String(page),
                "OnlyLookAbnormalFile": "0", "event": "homeListFile", "operateType": "4", "inDirectSpace": "false"])
            let d = o.dict("data") ?? [:]
            let list = d.arr("InfoList")
            for it in list {
                let id = String(it.int64("FileId") ?? 0)
                var f = RemoteFile(id: id, name: it.str("FileName") ?? "", path: id, isDir: it.int("Type") == 1, size: it.int64("Size") ?? 0)
                f.meta["etag"] = it.str("Etag") ?? ""
                f.meta["s3"] = it.str("S3KeyFlag") ?? ""
                out.append(f)
            }
            page += 1
            if list.isEmpty || d.str("Next") == "-1" { break }
        }
        return Providers.sortFiles(out)
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        let o = try await request("/file/download_info", method: "POST", json: [
            "driveId": 0, "etag": file.meta["etag"] ?? "", "fileId": Int64(file.id) ?? 0, "fileName": file.name,
            "s3keyFlag": file.meta["s3"] ?? "", "size": file.size, "type": 0])
        guard let raw = o.dict("data")?.str("DownloadUrl"), let ou = URL(string: raw) else { throw AppError.message("123 云盘：获取下载地址失败") }
        var target = ou
        if let p = URLComponents(url: ou, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "params" })?.value,
           let d = Data(base64Encoded: p), let s = String(data: d, encoding: .utf8), let u = URL(string: s) { target = u }
        var r = URLRequest(url: target)
        r.setValue("https://yun.123pan.com/", forHTTPHeaderField: "Referer")
        let (loc, body, st) = try await NoRedirect.location(r)
        var final = target
        if let loc, (300..<400).contains(st) { final = loc }
        else if let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let s = j.dict("data")?.str("redirect_url"), let u = URL(string: s) { final = u }
        let referer = "\(ou.scheme ?? "https")://\(ou.host ?? "")/"
        return PlayableMedia(url: final, title: file.name, headers: ["Referer": referer], resumeKey: resumeKey(file))
    }
}

// MARK: - In-app web login that captures an OAuth redirect

struct WebLoginView: UIViewRepresentable {
    let url: URL
    /// Return true when the URL was consumed (login finished).
    let onNavigate: (URL) -> Bool

    func makeCoordinator() -> Coord { Coord(onNavigate) }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        v.load(URLRequest(url: url))
        context.coordinator.web = v
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate {
        let cb: (URL) -> Bool
        weak var web: WKWebView?
        private var observer: NSKeyValueObservation?
        init(_ cb: @escaping (URL) -> Bool) { self.cb = cb }
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = a.request.url, cb(u) { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            if observer == nil {
                // fragment-only changes (#token) don't trigger navigations
                observer = w.observe(\.url, options: [.new]) { [weak self] wv, _ in
                    if let u = wv.url { _ = self?.cb(u) }
                }
            }
            if let u = w.url { _ = cb(u) }
        }
    }
}

struct OAuthLoginSheet: View {
    let source: MediaSource
    var onDone: (MediaSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var error: String?
    @State private var finished = false

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    WebLoginView(url: url) { u in handle(u) }
                } else if let error {
                    ContentUnavailableView("无法打开登录页", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("正在打开登录页…")
                }
            }
            .navigationTitle("登录 \(source.kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .task {
            do {
                if source.kind == .box {
                    guard let u = BoxProvider.authorizeURL(source), !(source.extra["clientId"] ?? "").trimmed.isEmpty else {
                        throw AppError.message("请先填写 Box 应用的 Client ID 和 Client Secret")
                    }
                    url = u
                } else {
                    url = try await OpListAuth.loginURL(source.kind)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func handle(_ u: URL) -> Bool {
        guard !finished else { return true }
        if source.kind == .box {
            guard u.absoluteString.hasPrefix(BoxProvider.redirect),
                  let code = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else { return false }
            finished = true
            Task {
                do { onDone(try await BoxProvider.token(source, code: code)); dismiss() }
                catch { finished = false; self.error = error.localizedDescription; url = nil }
            }
            return true
        }
        guard let t = OpListAuth.parseCallback(u) else { return false }
        finished = true
        var s = source
        s.token = t.access
        s.refreshToken = t.refresh
        s.tokenExpiry = t.access.isEmpty ? nil : Date().addingTimeInterval(3000)
        DispatchQueue.main.async { onDone(s); dismiss() }
        return true
    }
}
