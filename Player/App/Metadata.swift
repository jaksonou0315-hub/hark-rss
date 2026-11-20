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
    private static let year = re(#"(?<![0-9])((?:19|20)\d{2})(?![0-9pPiIxX])"#)
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
        if let m = first(year, original) {
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
}

enum TMDB {
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

    static func search(title: String, year: Int?, tv: Bool) async -> TMDBMatch? {
        if let m = await searchOne(title: title, year: year, tv: tv) { return m }
        if year != nil, let m = await searchOne(title: title, year: nil, tv: tv) { return m }
        return await searchOne(title: title, year: year, tv: !tv)
    }

    private static func searchOne(title: String, year: Int?, tv: Bool) async -> TMDBMatch? {
        var q = ["query": title, "include_adult": "false"]
        if let year { q[tv ? "first_air_date_year" : "year"] = String(year) }
        guard let r = request(tv ? "/search/tv" : "/search/movie", q),
              let o = try? await HTTP.json(r),
              let it = o.arr("results").first else { return nil }
        return match(it, kind: tv ? "tv" : "movie")
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
                         rating: (it["vote_average"] as? NSNumber)?.doubleValue)
    }

    /// Episode names/stills for a season.
    static func season(tvId: Int, season: Int) async -> [Int: (name: String, still: URL?, overview: String?)] {
        guard let r = request("/tv/\(tvId)/season/\(season)", [:]), let o = try? await HTTP.json(r) else { return [:] }
        var out: [Int: (name: String, still: URL?, overview: String?)] = [:]
        for e in o.arr("episodes") {
            guard let n = e.int("episode_number") else { continue }
            out[n] = (e.str("name") ?? "", e.str("still_path").flatMap { URL(string: imageBase + "w300" + $0) }, e.str("overview"))
        }
        return out
    }
}
