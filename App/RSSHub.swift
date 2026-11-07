import Foundation

/// RSSHub turns sites without RSS (微博, B站, 知乎, 小红书, 抖音 …) into feeds.
enum RSSHub {
    /// rsshub.app now refuses feed readers (403), so the default is a community mirror,
    /// and a failing RSSHub feed is retried on the other mirrors automatically.
    static let mirrors = [
        "https://rsshub.rssforever.com",
        "https://rsshub.ktachibana.party",
        "https://rsshub.umzzz.com",
        "https://rsshub.isrss.com",
        "https://rsshub.liumingye.cn",
        "https://hub.slarker.me",
    ]
    static let defaultInstance = mirrors[0]
    /// Hosts treated as RSSHub, so an old rsshub.app subscription is moved to a working mirror.
    static let knownHosts: Set<String> = Set(mirrors.compactMap { URL(string: $0)?.host } + ["rsshub.app", "rsshub.woodland.cafe", "rsshub.atgw.io"])

    static var custom: String? {
        let s = UserDefaults.standard.string(forKey: "rsshubInstance")?.trimmingCharacters(in: .whitespaces) ?? ""
        if s.isEmpty { return nil }
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }
    static var instance: String {
        get { custom ?? (UserDefaults.standard.string(forKey: "rsshubWorking") ?? defaultInstance) }
        set { UserDefaults.standard.set(newValue, forKey: "rsshubInstance") }
    }
    static func url(_ path: String) -> String { instance + path }

    /// If `raw` is an RSSHub address, the route path with its query ("/weibo/user/1?limit=20").
    static func path(of raw: String) -> String? {
        guard let c = URLComponents(string: raw), let host = c.host?.lowercased() else { return nil }
        var hosts = knownHosts
        if let cu = custom, let h = URL(string: cu)?.host?.lowercased() { hosts.insert(h) }
        guard hosts.contains(host) else { return nil }
        var p = c.percentEncodedPath
        if let q = c.percentEncodedQuery { p += "?" + q }
        return p.isEmpty ? nil : p
    }

    /// Instances to try for a route, best first: the user's own, the last one that worked, then the mirrors.
    static func candidates(for raw: String) -> [String] {
        guard let p = path(of: raw) else { return [raw] }
        var bases: [String] = []
        if let cu = custom { bases.append(cu) }
        if let w = UserDefaults.standard.string(forKey: "rsshubWorking") { bases.append(w) }
        bases += mirrors
        var seen = Set<String>()
        return bases.filter { seen.insert($0).inserted }.map { $0 + p }
    }

    static func remember(working url: String) {
        guard custom == nil, path(of: url) != nil, let c = URLComponents(string: url),
              let scheme = c.scheme, let host = c.host else { return }
        UserDefaults.standard.set("\(scheme)://\(host)", forKey: "rsshubWorking")
    }

    /// Plain-language reason for routes the public mirrors cannot serve.
    static func hint(for raw: String) -> String? {
        guard let p = path(of: raw) else { return nil }
        if p.hasPrefix("/weibo") { return "公共 RSSHub 实例暂时拉不到微博（微博要登录 Cookie），需要自建实例" }
        if p.hasPrefix("/xiaohongshu") || p.hasPrefix("/douyin") { return "公共 RSSHub 实例经常拉不到这个站，建议自建实例" }
        return nil
    }

    struct Template: Identifiable, Hashable {
        var id: String { path }
        let name: String
        let icon: String
        let path: String          // contains {id}
        let prompt: String
        let group: String
    }

    static let templates: [Template] = [
        .init(name: "微博用户", icon: "person.crop.circle", path: "/weibo/user/{id}", prompt: "微博用户 UID（数字）", group: "微博"),
        .init(name: "B站 UP 主投稿", icon: "play.tv", path: "/bilibili/user/video/{id}", prompt: "UP 主 UID（space.bilibili.com/后面的数字）", group: "B站"),
        .init(name: "B站 UP 主动态", icon: "bubble.left.and.text.bubble.right", path: "/bilibili/user/dynamic/{id}", prompt: "UP 主 UID", group: "B站"),
        .init(name: "知乎用户动态", icon: "text.bubble", path: "/zhihu/people/activities/{id}", prompt: "知乎用户 ID（zhihu.com/people/后面）", group: "知乎"),
        .init(name: "小红书用户笔记", icon: "book.closed", path: "/xiaohongshu/user/{id}/notes", prompt: "小红书用户 ID", group: "小红书"),
        .init(name: "抖音用户", icon: "music.note", path: "/douyin/user/{id}", prompt: "抖音用户 sec_uid", group: "抖音"),
        .init(name: "Telegram 频道", icon: "paperplane", path: "/telegram/channel/{id}", prompt: "频道用户名", group: "Telegram"),
    ]

    struct Hot: Identifiable, Hashable {
        var id: String { path }
        let name: String
        let icon: String
        let path: String
    }
    static let hot: [Hot] = [
        .init(name: "微博热搜", icon: "flame", path: "/weibo/search/hot"),
        .init(name: "知乎热榜", icon: "chart.line.uptrend.xyaxis", path: "/zhihu/hot"),
        .init(name: "B站热门", icon: "play.rectangle.on.rectangle", path: "/bilibili/popular/all"),
        .init(name: "36氪快讯", icon: "bolt", path: "/36kr/newsflashes"),
        .init(name: "豆瓣正在上映", icon: "film", path: "/douban/movie/playing"),
        .init(name: "GitHub Trending", icon: "chevron.left.forwardslash.chevron.right", path: "/github/trending/daily/any"),
    ]

    /// Recognises a profile link pasted from a site and returns its RSSHub feed.
    static func route(fromURL raw: String) -> (name: String, url: String, group: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules: [(String, String, String, String)] = [
            ("space\\.bilibili\\.com/(\\d+)", "/bilibili/user/video/$1", "B站 UP 主 $1", "B站"),
            ("bilibili\\.com/space/(\\d+)", "/bilibili/user/video/$1", "B站 UP 主 $1", "B站"),
            ("m\\.weibo\\.cn/(?:u|profile)/(\\d+)", "/weibo/user/$1", "微博 $1", "微博"),
            ("weibo\\.com/u/(\\d+)", "/weibo/user/$1", "微博 $1", "微博"),
            ("weibo\\.com/(\\d{5,})", "/weibo/user/$1", "微博 $1", "微博"),
            ("zhihu\\.com/people/([^/?#]+)", "/zhihu/people/activities/$1", "知乎 $1", "知乎"),
            ("xiaohongshu\\.com/user/profile/([0-9a-zA-Z]+)", "/xiaohongshu/user/$1/notes", "小红书 $1", "小红书"),
            ("douyin\\.com/user/([^/?#]+)", "/douyin/user/$1", "抖音用户", "抖音"),
            ("t\\.me/(?:s/)?([A-Za-z0-9_]+)", "/telegram/channel/$1", "Telegram $1", "Telegram"),
        ]
        for (pattern, path, name, group) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { continue }
            let id = String(s[r])
            return (name.replacingOccurrences(of: "$1", with: id),
                    url(path.replacingOccurrences(of: "$1", with: id)), group)
        }
        return nil
    }
}
