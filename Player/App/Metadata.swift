import Foundation

struct ParsedName {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?
    var isEpisode: Bool { episode != nil }
}

enum NameParser {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let seasonEp = re(#"[Ss](\d{1,2})[ ._-]?[Ee][Pp]?(\d{1,4})"#)
    private static let xEp = re(#"(?<![0-9])(\d{1,2})x(\d{2,3})(?![0-9])"#)
    private static let cnEp = re(#"第\s*([0-9一二三四五六七八九十百零]+)\s*[集话話期]"#)
    private static let epOnly = re(#"(?<![A-Za-z0-9])(?:EP?|Episode[ ._]?)(\d{1,4})(?![0-9])"#)
    private static let cnSeason = re(#"第\s*([0-9一二三四五六七八九十]+)\s*季"#)
    private static let enSeason = re(#"(?<![A-Za-z])(?:Season[ ._]?|S)(\d{1,2})(?![0-9])"#)
    private static let yearRe = re(#"(?<![0-9])((?:19|20)\d{2})(?![0-9pPiIxX])"#)
    private static let brackets = re(#"[\[【(（][^\]】)）]*[\]】)）]"#)
    private static let tags = re(#"(?<![A-Za-z0-9])(2160p|1080p|1080i|720p|480p|4k|uhd|bluray|blu-ray|bdrip|brrip|web-?dl|webrip|hdtv|hdrip|dvdrip|x26[45]|h\.?26[45]|hevc|avc|remux|hdr10?\+?|dv|dolby|dts(-hd)?|truehd|atmos|aac|ac3|ddp?5\.1|10bit|60fps|complete|国语|中字|双语|简繁|内封|内嵌)(?![A-Za-z0-9])"#)
    private static let leadingNumber = re(#"^\s*(\d{1,3})\s*$"#)

    static func cnNumber(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let map: [Character: Int] = ["零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, cur = 0
        for ch in s {
            if let d = map[ch] { cur = d }
            else if ch == "十" { total += (cur == 0 ? 1 : cur) * 10; cur = 0 }
            else if ch == "百" { total += (cur == 0 ? 1 : cur) * 100; cur = 0 }
        }
        let r = total + cur
        return r > 0 ? r : nil
    }

    private static func first(_ r: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }
    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return nil }
        return String(s[r])
    }

    static func cleanTitle(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–·:：,，&+").union(.whitespaces))
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
    }

    /// `parents` = folder names from nearest to farthest.
    static func parse(_ fileName: String, parents: [String] = []) -> ParsedName {
        let original = (fileName as NSString).deletingPathExtension
        var cutAt = original.endIndex
        var season: Int? = nil, episode: Int? = nil, year: Int? = nil

        func markCut(_ m: NSTextCheckingResult) {
            if let r = Range(m.range, in: original), r.lowerBound < cutAt { cutAt = r.lowerBound }
        }
        if let m = first(seasonEp, original) {
            season = group(m, 1, original).flatMap { Int($0) }; episode = group(m, 2, original).flatMap { Int($0) }; markCut(m)
        } else if let m = first(xEp, original) {
            season = group(m, 1, original).flatMap { Int($0) }; episode = group(m, 2, original).flatMap { Int($0) }; markCut(m)
        } else if let m = first(cnEp, original) {
            episode = group(m, 1, original).flatMap { cnNumber($0) }; markCut(m)
        } else if let m = first(epOnly, original) {
            episode = group(m, 1, original).flatMap { Int($0) }; markCut(m)
        } else if let m = first(leadingNumber, original) {
            episode = group(m, 1, original).flatMap { Int($0) }; markCut(m)
        }
        if let m = first(cnSeason, original) {
            if season == nil { season = group(m, 1, original).flatMap { cnNumber($0) } }
            markCut(m)
        }
        if let m = first(yearRe, original) {
            year = group(m, 1, original).flatMap { Int($0) }
            // a leading year ("2012.mkv") is a title, not a year
            if let r = Range(m.range, in: original), r.lowerBound != original.startIndex { markCut(m) } else if original.count <= 5 { year = nil }
        }
        if let m = first(tags, original) { markCut(m) }

        var head = String(original[..<cutAt])
        let withoutBrackets = brackets.stringByReplacingMatches(in: head, range: NSRange(head.startIndex..., in: head), withTemplate: " ")
        if !cleanTitle(withoutBrackets).isEmpty {
            head = withoutBrackets
        } else if let m = first(brackets, head), let r = Range(m.range, in: head) {
            head = String(head[r]).trimmingCharacters(in: CharacterSet(charactersIn: "[]【】()（）"))
        }
        var title = cleanTitle(head)
        // Chinese + English names ("流浪地球 The Wandering Earth") – keep the CJK part for TMDB zh search
        if let cjkEnd = title.firstIndex(where: { $0.isASCII && $0.isLetter }),
           title[..<cjkEnd].contains(where: { !$0.isASCII }) {
            let cjk = cleanTitle(String(title[..<cjkEnd]))
            if !cjk.isEmpty { title = cjk }
        }

        // Episode files often carry no title: use the folder ("Show/Season 1/01.mkv")
        if title.isEmpty || (episode != nil && title.count <= 2) {
            for p in parents {
                var pp = p
                if let m = first(cnSeason, pp) ?? first(enSeason, pp) {
                    if season == nil { season = group(m, 1, pp).flatMap { cnNumber($0) } }
                    if let r = Range(m.range, in: pp) { pp.removeSubrange(r) }
                }
                let parsedParent = parse(pp + ".x")
                if !parsedParent.title.isEmpty {
                    title = parsedParent.title
                    if year == nil { year = parsedParent.year }
                    break
                }
            }
        }
        if episode != nil && season == nil { season = 1 }
        if title.isEmpty { title = cleanTitle(original) }
        return ParsedName(title: title, year: year, season: season, episode: episode)
    }
}

// MARK: - TMDB

struct TMDBMatch: Codable, Hashable {
    var id: Int
    var kind: String          // movie | tv
    var title: String
    var originalTitle: String?
    var year: Int?
    var overview: String?
    var poster: URL?
    var backdrop: URL?
    var rating: Double?
    var genreIds: [Int] = []
    var date: String? = nil
}

enum TMDB {
    static func genreName(_ id: Int) -> String? {
        let m: [Int: String] = [28: "动作", 12: "冒险", 16: "动画", 35: "喜剧", 80: "犯罪", 99: "纪录", 18: "剧情", 10751: "家庭",
                                14: "奇幻", 36: "历史", 27: "恐怖", 10402: "音乐", 9648: "悬疑", 10749: "爱情", 878: "科幻",
                                10770: "电视电影", 53: "惊悚", 10752: "战争", 37: "西部", 10759: "动作冒险", 10762: "儿童",
                                10763: "新闻", 10764: "真人秀", 10765: "Sci-Fi & Fantasy", 10766: "肥皂剧", 10767: "脱口秀",
                                10768: "War & Politics"]
        return m[id]
    }
    static let imageBase = "https://image.tmdb.org/t/p/"

    private static func request(_ path: String, _ query: [String: String]) -> URLRequest? {
        let key = AppSettings.shared.tmdbKey.trimmed
        guard !key.isEmpty else { return nil }
        var c = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: AppSettings.shared.tmdbLanguage))
        var headers = ["Accept": "application/json"]
        if key.hasPrefix("eyJ") { headers["Authorization"] = "Bearer \(key)" } else { items.append(URLQueryItem(name: "api_key", value: key)) }
        c.queryItems = items
        guard let url = c.url else { return nil }
        return HTTP.request(url, headers: headers)
    }

    static func test() async throws {
        guard let r = request("/configuration", [:]) else { throw AppError.message("请先填写 TMDB API Key") }
        _ = try await HTTP.json(r)
    }

    /// One search per show/movie, cached on disk by normalized title + year (rescans and relaunches don't hit TMDB again).
    static func search(title: String, year: Int?, tv: Bool) async -> TMDBMatch? {
        let key = TMDBCache.searchKey(title, year, tv)
        if let hit = TMDBCache.shared.match(key) { return hit }
        var m = await searchOne(title: title, year: year, tv: tv)
        if m == nil, year != nil { m = await searchOne(title: title, year: nil, tv: tv) }
        if m == nil { m = await searchOne(title: title, year: year, tv: !tv) }
        if let m { TMDBCache.shared.setMatch(key, m) }
        return m
    }

    private static func searchOne(title: String, year: Int?, tv: Bool) async -> TMDBMatch? {
        var q = ["query": title, "include_adult": "false"]
        if let year { q[tv ? "first_air_date_year" : "year"] = String(year) }
        guard let r = request(tv ? "/search/tv" : "/search/movie", q),
              let o = try? await HTTP.json(r),
              let it = o.arr("results").first else { return nil }
        return match(it, kind: tv ? "tv" : "movie")
    }

    /// All results for the 编辑信息 sheet (no cache, user-driven).
    static func searchList(_ query: String, tv: Bool) async -> [TMDBMatch] {
        guard let r = request(tv ? "/search/tv" : "/search/movie", ["query": query, "include_adult": "false"]),
              let o = try? await HTTP.json(r) else { return [] }
        return o.arr("results").prefix(20).map { match($0, kind: tv ? "tv" : "movie") }
    }

    /// Direct lookup, used for [tmdbid=123] in file / folder names.
    static func byId(_ id: Int, tv: Bool) async -> TMDBMatch? {
        guard let r = request("/\(tv ? "tv" : "movie")/\(id)", [:]), let o = try? await HTTP.json(r) else { return nil }
        var m = match(o, kind: tv ? "tv" : "movie")
        if m.genreIds.isEmpty { m.genreIds = o.arr("genres").compactMap { $0.int("id") } }
        return m.id == 0 ? nil : m
    }

    /// "[tmdbid=123]", "{tmdb-123}", "tmdbid-123" anywhere in a path.
    static func idInPath(_ s: String) -> Int? {
        guard let r = s.range(of: #"tmdb(id)?[=\-]\s*(\d+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(s[r].filter(\.isNumber))
    }

    static func match(_ it: [String: Any], kind: String) -> TMDBMatch {
        let date = it.str(kind == "tv" ? "first_air_date" : "release_date") ?? ""
        return TMDBMatch(id: it.int("id") ?? 0, kind: kind,
                         title: it.str(kind == "tv" ? "name" : "title") ?? "",
                         originalTitle: it.str(kind == "tv" ? "original_name" : "original_title"),
                         year: Int(date.prefix(4)),
                         overview: it.str("overview"),
                         poster: it.str("poster_path").flatMap { URL(string: imageBase + "w500" + $0) },
                         backdrop: it.str("backdrop_path").flatMap { URL(string: imageBase + "w1280" + $0) },
                         rating: (it["vote_average"] as? NSNumber)?.doubleValue,
                         genreIds: (it["genre_ids"] as? [Int]) ?? [],
                         date: date.isEmpty ? nil : date)
    }

    /// Episode names/stills for a season.
    /// Season details are fetched once per show+season and cached (3 days, so airing shows pick up new episodes).
    static func season(tvId: Int, season: Int) async -> [Int: (name: String, still: URL?, overview: String?)] {
        let key = "\(tvId)|\(season)|\(AppSettings.shared.tmdbLanguage)"
        if let c = TMDBCache.shared.season(key) {
            return Dictionary(uniqueKeysWithValues: c.map { ($0.key, (name: $0.value.name, still: $0.value.still, overview: $0.value.overview)) })
        }
        guard let r = request("/tv/\(tvId)/season/\(season)", [:]), let o = try? await HTTP.json(r) else { return [:] }
        var out: [Int: (name: String, still: URL?, overview: String?)] = [:]
        var store: [Int: TMDBCache.Ep] = [:]
        for e in o.arr("episodes") {
            guard let n = e.int("episode_number") else { continue }
            out[n] = (e.str("name") ?? "", e.str("still_path").flatMap { URL(string: imageBase + "w300" + $0) }, e.str("overview"))
            store[n] = TMDBCache.Ep(name: out[n]!.name, still: out[n]!.still, overview: out[n]!.overview)
        }
        TMDBCache.shared.setSeason(key, store)
        return out
    }
}

// MARK: - Rich details for the detail page

struct TMDBCast: Hashable { var name: String; var role: String; var photo: URL? }

struct TMDBDetails {
    var title: String
    var date: String?          // yyyy/M/d
    var countries: [String]
    var genres: [String]
    var rating: Double?
    var voteCount: Int?
    var overview: String?
    var logo: URL?
    var posterHi: URL?
    var totalEpisodes: Int?
    var seasonCount: Int?
    var runtime: Int?
    var cast: [TMDBCast]
    var tagline: String?
    var certification: String?
    var related: [Int] = []     // TMDB recommendations + similar, best first
    var keywords: [String] = [] // lowercased
}

extension TMDB {
    nonisolated(unsafe) private static var cache: [String: TMDBDetails] = [:]
    private static let cacheLock = NSLock()
    private static func cached(_ k: String) -> TMDBDetails? { cacheLock.lock(); defer { cacheLock.unlock() }; return cache[k] }
    private static func store(_ k: String, _ d: TMDBDetails) { cacheLock.lock(); cache[k] = d; cacheLock.unlock() }

    static func details(id: Int, tv: Bool) async -> TMDBDetails? {
        let key = "\(tv ? "tv" : "movie")-\(id)"
        if let c = cached(key) { return c }
        let lang = AppSettings.shared.tmdbLanguage
        let short = String(lang.prefix(2))
        guard let r = request("/\(tv ? "tv" : "movie")/\(id)",
                              ["append_to_response": tv ? "aggregate_credits,images,content_ratings,recommendations,similar,keywords" : "credits,images,release_dates,recommendations,similar,keywords",
                               "include_image_language": "\(short),en,null"]),
              let o = try? await HTTP.json(r) else { return nil }
        let rawDate = o.str(tv ? "first_air_date" : "release_date") ?? ""
        var date: String?
        let parts = rawDate.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3 { date = "\(parts[0])/\(parts[1])/\(parts[2])" }
        let countryCodes: [String] = tv ? ((o["origin_country"] as? [String]) ?? [])
                                        : o.arr("production_countries").compactMap { $0.str("iso_3166_1") }
        let loc = Locale(identifier: lang)
        let countries = countryCodes.prefix(2).map { loc.localizedString(forRegionCode: $0) ?? $0 }
        let genres = o.arr("genres").compactMap { $0.str("name") }
        // logo: prefer UI language, then English, then any
        let logos = o.dict("images")?.arr("logos") ?? []
        let logo = (logos.first { $0.str("iso_639_1") == short } ?? logos.first { $0.str("iso_639_1") == "en" } ?? logos.first)?
            .str("file_path").flatMap { URL(string: imageBase + "w500" + $0) }
        // cast
        var cast: [TMDBCast] = []
        if tv {
            for c in (o.dict("aggregate_credits")?.arr("cast") ?? []).prefix(20) {
                let role = c.arr("roles").first?.str("character") ?? ""
                cast.append(TMDBCast(name: c.str("name") ?? "", role: role, photo: c.str("profile_path").flatMap { URL(string: imageBase + "w185" + $0) }))
            }
        } else {
            for c in (o.dict("credits")?.arr("cast") ?? []).prefix(20) {
                cast.append(TMDBCast(name: c.str("name") ?? "", role: c.str("character") ?? "", photo: c.str("profile_path").flatMap { URL(string: imageBase + "w185" + $0) }))
            }
        }
        var cert: String?
        if tv {
            let rs = o.dict("content_ratings")?.arr("results") ?? []
            cert = (rs.first { $0.str("iso_3166_1") == "US" } ?? rs.first)?.str("rating")
        } else {
            let rs = o.dict("release_dates")?.arr("results") ?? []
            let pick = rs.first { $0.str("iso_3166_1") == "US" } ?? rs.first
            cert = pick?.arr("release_dates").compactMap { $0.str("certification") }.first { !$0.isEmpty }
        }
        let d = TMDBDetails(title: o.str(tv ? "name" : "title") ?? "",
                            date: date, countries: countries, genres: genres,
                            rating: (o["vote_average"] as? NSNumber)?.doubleValue,
                            voteCount: o.int("vote_count"),
                            overview: o.str("overview"),
                            logo: logo,
                            posterHi: o.str("poster_path").flatMap { URL(string: imageBase + "w780" + $0) },
                            totalEpisodes: o.int("number_of_episodes"),
                            seasonCount: o.int("number_of_seasons"),
                            runtime: o.int("runtime"),
                            cast: cast,
                            tagline: o.str("tagline"),
                            certification: cert,
                            related: {
                                var seen = Set<Int>(); var out: [Int] = []
                                for k in ["recommendations", "similar"] {
                                    for r in o.dict(k)?.arr("results") ?? [] { if let i = r.int("id"), seen.insert(i).inserted { out.append(i) } }
                                }
                                return out
                            }(),
                            keywords: ((o.dict("keywords")?.arr(tv ? "results" : "keywords")) ?? []).compactMap { $0.str("name")?.lowercased() })
        store(key, d)
        return d
    }
}


// MARK: - TMDB disk cache

final class TMDBCache: @unchecked Sendable {
    static let shared = TMDBCache()
    struct Ep: Codable { var name: String; var still: URL?; var overview: String? }
    private struct SeasonEntry: Codable { var at: Date; var eps: [Int: Ep] }
    private struct Disk: Codable { var matches: [String: TMDBMatch] = [:]; var seasons: [String: SeasonEntry] = [:] }
    private var disk = Disk()
    private var dirty = false
    private let lock = NSLock()
    private let url: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("tmdb-cache.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(Disk.self, from: d) { disk = v }
    }

    static func searchKey(_ title: String, _ year: Int?, _ tv: Bool) -> String {
        let norm = title.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return "\(tv ? "tv" : "movie")|\(norm)|\(year ?? 0)|\(AppSettings.shared.tmdbLanguage)"
    }

    func match(_ k: String) -> TMDBMatch? { lock.lock(); defer { lock.unlock() }; return disk.matches[k] }
    func setMatch(_ k: String, _ m: TMDBMatch) { lock.lock(); disk.matches[k] = m; dirty = true; lock.unlock() }

    func season(_ k: String) -> [Int: Ep]? {
        lock.lock(); defer { lock.unlock() }
        guard let e = disk.seasons[k], Date().timeIntervalSince(e.at) < 3 * 86_400 else { return nil }
        return e.eps
    }
    func setSeason(_ k: String, _ eps: [Int: Ep]) { lock.lock(); disk.seasons[k] = SeasonEntry(at: Date(), eps: eps); dirty = true; lock.unlock() }

    func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        let snapshot = disk
        lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
    }
}
