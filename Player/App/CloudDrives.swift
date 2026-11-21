import Foundation
import CryptoKit

enum Hash {
    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
    static func md5(_ s: String) -> String { hex(Insecure.MD5.hash(data: Data(s.utf8))) }
    static func sha256(_ s: String) -> String { hex(SHA256.hash(data: Data(s.utf8))) }
    static func randomHex32() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

// MARK: - 夸克网盘 (Quark TV open API, QR login with the Quark app — same approach as OpenList's QuarkTV driver)

final class QuarkTVProvider: SourceProvider {
    private(set) var source: MediaSource
    init(_ s: MediaSource) {
        source = s
        if (source.extra["deviceId"] ?? "").isEmpty { source.extra["deviceId"] = Hash.randomHex32() }
    }

    static let api = "https://open-api-drive.quark.cn"
    static let clientID = "d3194e61504e493eb6222857bccfed94"
    static let signKey = "kw2dvtd7p4t3pjl2d9ed9yc8yej8kw2d"
    static let appVer = "1.8.2.2"
    static let channel = "GENERAL"
    static let codeApi = "http://api.extscreen.com/quarkdrive"
    static let ua = "Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1"

    private static func deviceParams(_ deviceId: String, reqId: String) -> [String: String] {
        ["req_id": reqId, "app_ver": appVer, "device_id": deviceId, "device_brand": "Xiaomi", "platform": "tv",
         "device_name": "M2004J7AC", "device_model": "M2004J7AC", "build_device": "M2004J7AC", "build_product": "M2004J7AC",
         "device_gpu": "Adreno (TM) 550", "activity_rect": "{}", "channel": channel]
    }

    private static func sign(_ method: String, _ path: String, deviceId: String) -> (tm: String, token: String, reqId: String) {
        let tm = String(Int64(Date().timeIntervalSince1970 * 1000))
        return (tm, Hash.sha256("\(method)&\(path)&\(tm)&\(signKey)"), Hash.md5(deviceId + tm))
    }

    struct QuarkError: Error { var errno: Int; var message: String }

    static func call(_ path: String, query: [String: String], accessToken: String, deviceId: String) async throws -> [String: Any] {
        let s = sign("GET", path, deviceId: deviceId)
        var q = deviceParams(deviceId, reqId: s.reqId)
        q["access_token"] = accessToken
        for (k, v) in query { q[k] = v }
        var c = URLComponents(string: api + path)!
        c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        let r = HTTP.request(c.url!, headers: ["Accept": "application/json, text/plain, */*", "User-Agent": ua,
                                               "x-pan-tm": s.tm, "x-pan-token": s.token, "x-pan-client-id": clientID])
        let (d, _) = try await HTTP.data(r)
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw AppError.message("夸克：无法解析服务器响应") }
        let errno = o.int("errno") ?? 0
        let status = o.int("status") ?? 200
        if errno != 0 || status >= 400 {
            throw QuarkError(errno: errno, message: o.str("error_info") ?? "夸克请求失败 (\(errno))")
        }
        return o
    }

    // QR login
    static func startQR(deviceId: String) async throws -> (image: Data?, text: String?, queryToken: String) {
        let o = try await call("/oauth/authorize", query: ["auth_type": "code", "client_id": clientID, "scope": "netdisk",
                                                         "qrcode": "1", "qr_width": "460", "qr_height": "460"], accessToken: "", deviceId: deviceId)
        guard let qt = o.str("query_token") else { throw AppError.message("获取夸克二维码失败") }
        var raw = o.str("qr_data") ?? ""
        if let r = raw.range(of: "base64,") { raw = String(raw[r.upperBound...]) }
        if let img = Data(base64Encoded: raw, options: .ignoreUnknownCharacters), img.count > 100 { return (img, nil, qt) }
        return (nil, raw.isEmpty ? nil : raw, qt)
    }
    /// nil while the user has not confirmed yet
    static func pollCode(queryToken: String, deviceId: String) async -> String? {
        guard let o = try? await call("/oauth/code", query: ["client_id": clientID, "scope": "netdisk", "query_token": queryToken],
                                      accessToken: "", deviceId: deviceId) else { return nil }
        let c = o.str("code") ?? ""
        return c.isEmpty ? nil : c
    }
    static func token(_ s: MediaSource, code: String? = nil, refresh: String? = nil) async throws -> MediaSource {
        var s = s
        let deviceId = s.extra["deviceId"] ?? Hash.randomHex32()
        s.extra["deviceId"] = deviceId
        let sg = sign("POST", "/token", deviceId: deviceId)
        var body: [String: Any] = deviceParams(deviceId, reqId: sg.reqId)
        if let code { body["code"] = code }
        if let refresh { body["refresh_token"] = refresh }
        let o = try await HTTP.json(HTTP.request(URL(string: codeApi + "/token")!, method: "POST", json: body))
        let d = o.dict("data") ?? [:]
        guard o.int("code") == 200, let rt = d.str("refresh_token"), !rt.isEmpty else {
            throw AppError.message(o.str("message") ?? "夸克登录失败，请重新扫码")
        }
        s.refreshToken = rt
        s.token = d.str("access_token") ?? ""
        s.tokenExpiry = Date().addingTimeInterval(Double(d.int("expires_in") ?? 3600) - 120)
        return s
    }

    private func ensureToken(force: Bool = false) async throws {
        if !force, !source.token.isEmpty, let e = source.tokenExpiry, e > Date() { return }
        guard !source.refreshToken.isEmpty else { throw AppError.message("请先扫码登录夸克网盘") }
        source = try await Self.token(source, refresh: source.refreshToken)
        await SourceStore.shared.updateCredentials(source)
    }

    private func get(_ path: String, _ q: [String: String]) async throws -> [String: Any] {
        try await ensureToken()
        do {
            return try await Self.call(path, query: q, accessToken: source.token, deviceId: source.extra["deviceId"] ?? "")
        } catch let e as QuarkError {
            let m = e.message.lowercased()
            if e.errno == 10001 || e.errno == 11001 || m.contains("token") {
                try await ensureToken(force: true)
                return try await Self.call(path, query: q, accessToken: source.token, deviceId: source.extra["deviceId"] ?? "")
            }
            throw AppError.message("夸克：\(e.message)")
        }
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        let parent = dir?.path ?? "0"
        var out: [RemoteFile] = []
        var page = 0
        let size = 100
        while true {
            let o = try await get("/file", ["method": "list", "parent_fid": parent, "order_by": "1", "desc": "0", "category": "",
                                            "source": "", "ex_source": "", "list_all": "0", "page_size": String(size), "page_index": String(page)])
            let data = o.dict("data") ?? [:]
            let files = data.arr("files")
            for it in files {
                let fid = it.str("fid") ?? ""
                var f = RemoteFile(id: fid, name: it.str("filename") ?? "", path: fid, isDir: it.int("isdir") == 1, size: it.int64("size") ?? 0)
                f.meta["category"] = it.str("category") ?? ""
                if let t = it.str("thumbnail_url"), let u = URL(string: t) { f.posterURL = u }
                out.append(f)
            }
            let total = data.int("total_count") ?? 0
            page += 1
            if files.isEmpty || page * size >= total || out.count > 50000 { break }
        }
        return Providers.sortFiles(out)
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        let common = ["group_by": "source", "fid": file.path, "resolution": "low,normal,high,super,2k,4k", "support": "dolby_vision"]
        if source.extra["linkMode"] == "streaming", file.isVideo {
            var q = common; q["method"] = "streaming"
            let o = try await get("/file", q)
            let infos = o.dict("data")?.arr("video_info") ?? []
            let best = infos.filter { !($0.str("url") ?? "").isEmpty }.max { ($0.int("height") ?? 0) < ($1.int("height") ?? 0) }
            if let s = best?.str("url"), let u = URL(string: s) {
                return PlayableMedia(url: u, title: file.name, headers: ["User-Agent": Self.ua], resumeKey: resumeKey(file))
            }
        }
        var q = common; q["method"] = "download"
        let o = try await get("/file", q)
        guard let s = o.dict("data")?.str("download_url"), let u = URL(string: s) else { throw AppError.message("夸克：获取播放地址失败") }
        return PlayableMedia(url: u, title: file.name, headers: ["User-Agent": Self.ua], resumeKey: resumeKey(file))
    }
}

// MARK: - 光鸭云盘 (unofficial web API, SMS login — same approach as OpenList's GuangYaPan driver)

final class GuangyaProvider: SourceProvider {
    private(set) var source: MediaSource
    init(_ s: MediaSource) {
        source = s
        if (source.extra["deviceId"] ?? "").count != 32 { source.extra["deviceId"] = Hash.randomHex32() }
    }

    static let account = "https://account.guangyapan.com"
    static let api = "https://api.guangyapan.com"
    static let defaultClientID = "aMe-8VSlkrbQXpUR"

    static func clientId(_ s: MediaSource) -> String {
        let c = (s.extra["clientId"] ?? "").trimmed
        return c.isEmpty ? defaultClientID : c
    }
    static func accountHeaders(_ s: MediaSource) -> [String: String] {
        let did = s.extra["deviceId"] ?? ""
        return ["Accept": "application/json, text/plain, */*", "X-Device-Model": "chrome%2F147.0.0.0", "X-Device-Name": "PC-Chrome",
                "X-Device-Sign": "wdi10." + did, "X-Net-Work-Type": "NONE", "X-OS-Version": "MacIntel", "X-Platform-Version": "1",
                "X-Protocol-Version": "301", "X-Provider-Name": "NONE", "X-SDK-Version": "9.0.2", "X-Client-Id": clientId(s),
                "X-Client-Version": "0.0.1", "X-Device-Id": did]
    }
    static func phoneE164(_ p: String) -> String {
        var s = p.replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("+86") { return "+86 " + s.dropFirst(3) }
        if s.hasPrefix("+") { return s }
        s = s.filter(\.isNumber)
        if s.count == 13, s.hasPrefix("86") { s = String(s.dropFirst(2)) }
        return s.count == 11 ? "+86 " + s : s
    }

    /// Step 1: send the SMS. Returns verification_id.
    static func sendSMS(_ s: MediaSource, phone: String) async throws -> String {
        let phone = phoneE164(phone)
        var h = accountHeaders(s)
        let cap = try await HTTP.json(HTTP.request(URL(string: account + "/v1/shield/captcha/init")!, method: "POST", headers: h,
            json: ["client_id": clientId(s), "action": "POST:/v1/auth/verification", "device_id": s.extra["deviceId"] ?? "",
                   "meta": ["username": phone, "phone_number": phone, "VERIFICATION_PHONE": phone]]))
        if let ct = cap.str("captcha_token"), !ct.isEmpty { h["X-Captcha-Token"] = ct }
        if let u = cap.str("url"), !u.isEmpty {
            throw AppError.message("光鸭要求人机验证，暂时无法在 App 内发短信。请在下方「手动填写令牌」粘贴 refresh_token。")
        }
        let o = try await HTTP.json(HTTP.request(URL(string: account + "/v1/auth/verification")!, method: "POST", headers: h,
            json: ["phone_number": phone, "target": "ANY", "client_id": clientId(s)]))
        guard let vid = o.str("verification_id"), !vid.isEmpty else { throw AppError.message(o.str("error_description") ?? "发送验证码失败") }
        return vid
    }

    /// Step 2: verify the code and sign in.
    static func signIn(_ s: MediaSource, phone: String, code: String, verificationId: String) async throws -> MediaSource {
        let h = accountHeaders(s)
        let v = try await HTTP.json(HTTP.request(URL(string: account + "/v1/auth/verification/verify")!, method: "POST", headers: h,
            json: ["verification_id": verificationId, "verification_code": code, "client_id": clientId(s)]))
        guard let vt = v.str("verification_token"), !vt.isEmpty else { throw AppError.message(v.str("error_description") ?? "验证码错误") }
        let o = try await HTTP.json(HTTP.request(URL(string: account + "/v1/auth/signin")!, method: "POST", headers: h,
            json: ["verification_code": code, "verification_token": vt, "username": phoneE164(phone), "client_id": clientId(s)]))
        return try apply(o, to: s)
    }

    private static func apply(_ o: [String: Any], to s: MediaSource) throws -> MediaSource {
        guard let at = o.str("access_token"), !at.isEmpty else { throw AppError.message(o.str("error_description") ?? o.str("error") ?? "光鸭登录失败") }
        var s = s
        s.token = at
        if let rt = o.str("refresh_token"), !rt.isEmpty { s.refreshToken = rt }
        s.tokenExpiry = Date().addingTimeInterval(Double(o.int("expires_in") ?? 3600) - 120)
        return s
    }

    private func refresh() async throws {
        guard !source.refreshToken.trimmed.isEmpty else { throw AppError.message("光鸭登录已过期，请重新短信登录") }
        let o = try await HTTP.json(HTTP.request(URL(string: Self.account + "/v1/auth/token")!, method: "POST", headers: Self.accountHeaders(source),
            json: ["client_id": Self.clientId(source), "grant_type": "refresh_token", "refresh_token": source.refreshToken.trimmed]))
        source = try Self.apply(o, to: source)
        await SourceStore.shared.updateCredentials(source)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        if source.token.isEmpty || (source.tokenExpiry.map { $0 < Date() } ?? false) { try await refresh() }
        func once() async throws -> (Int, [String: Any]) {
            let r = HTTP.request(URL(string: Self.api + path)!, method: "POST",
                                 headers: ["Authorization": "Bearer \(source.token)", "Did": source.extra["deviceId"] ?? "", "Dt": "4",
                                           "Accept": "application/json, text/plain, */*"], json: body)
            let (d, h) = try await HTTP.data(r)
            return (h.statusCode, (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:])
        }
        var (st, o) = try await once()
        if st == 401 || st == 403 {
            try await refresh()
            (st, o) = try await once()
        }
        guard (200..<300).contains(st) else { throw AppError.message("光鸭请求失败 HTTP \(st)") }
        let code = o.int("code") ?? 0
        let msg = (o.str("msg") ?? "").trimmed
        if code != 0 && !(msg.isEmpty || msg.lowercased() == "success") { throw AppError.message("光鸭：\(msg.isEmpty ? "错误 \(code)" : msg)") }
        return o
    }

    func list(_ dir: RemoteFile?) async throws -> [RemoteFile] {
        let parent = dir?.path ?? ""
        var out: [RemoteFile] = []
        var seen = Set<String>()
        var page = 0
        let size = 100
        var pageCap = 0          // what the server actually returns per page (may be capped below `size`)
        var stale = 0
        while page < 2000 {
            let o = try await post("/userres/v1/file/get_file_list", ["parentId": parent, "page": page, "pageSize": size, "orderBy": 3, "sortType": 1])
            let data = o.dict("data") ?? [:]
            let list = data.arr("list")
            if list.isEmpty { break }
            pageCap = max(pageCap, list.count)
            var fresh = 0
            for it in list {
                let id = it.str("fileId") ?? ""
                guard seen.insert(id).inserted else { continue }
                fresh += 1
                var f = RemoteFile(id: id, name: it.str("fileName") ?? "", path: id, isDir: it.int("resType") == 2, size: it.int64("fileSize") ?? 0)
                f.meta["gcid"] = it.str("gcid") ?? ""
                f.meta["fileType"] = it.str("fileType") ?? ""
                if let t = it.str("thumbnail"), !t.isEmpty, let u = URL(string: t) { f.posterURL = u }
                out.append(f)
            }
            let total = data.int("total") ?? 0
            page += 1
            if total > 0 && out.count >= total { break }
            if total == 0 && list.count < pageCap { break }
            // a page with nothing new (1-based paging repeats page 0, or the server ignores `page`): allow one, then stop
            if fresh == 0 { stale += 1; if stale >= 2 { break } } else { stale = 0 }
        }
        return Providers.sortFiles(out)
    }

    func playable(_ file: RemoteFile) async throws -> PlayableMedia {
        func url(_ o: [String: Any]) -> URL? {
            let d = o.dict("data") ?? [:]
            let s = (d.str("signedURL") ?? "").isEmpty ? (d.str("downloadUrl") ?? "") : d.str("signedURL")!
            return URL(string: s)
        }
        let gcid = file.meta["gcid"] ?? ""
        let preferVod = source.extra["linkMode"] != "download"
        if preferVod, file.isVideo, !gcid.isEmpty,
           let o = try? await post("/nd.bizuserres.s/v1/file/get_vod_download_url", ["fileId": file.path, "gcid": gcid]), let u = url(o) {
            return PlayableMedia(url: u, title: file.name, resumeKey: resumeKey(file))
        }
        let o = try await post("/nd.bizuserres.s/v1/get_res_download_url", ["fileId": file.path])
        guard let u = url(o) else { throw AppError.message("光鸭：获取播放地址失败") }
        return PlayableMedia(url: u, title: file.name, resumeKey: resumeKey(file))
    }
}
