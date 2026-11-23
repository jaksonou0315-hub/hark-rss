import Foundation

/// Which source supplies the rating and synopsis shown on the poster wall. Posters, categories and
/// episodes always come from TMDB; 「豆瓣」 swaps in Douban's score and Chinese synopsis when found.
enum MetaSource {
    static let key = "meta.source"
    static var douban: Bool { UserDefaults.standard.string(forKey: key) == "douban" }
}

struct DoubanInfo { var id: String; var rating: Double?; var intro: String? }

enum Douban {
    enum Result { case found(DoubanInfo), notFound, failed }
    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private static func get(_ url: URL, referer: String) async -> Data?? {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.setValue(referer, forHTTPHeaderField: "Referer")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else { return .none }
        if code == 404 { return .some(nil) }
        guard code == 200 else { return .none }
        return .some(d)
    }

    static func lookup(title: String, alt: String?, year: Int?, tv: Bool) async -> Result {
        var id: String?
        for q in [title, alt].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            switch await search(q, year: year, tv: tv) {
            case .failed: return .failed
            case .found(let x): id = x
            case .notFound: break
            }
            if id != nil { break }
        }
        guard let id else { return .notFound }
        for kind in tv ? ["tv", "movie"] : ["movie", "tv"] {
            let url = URL(string: "https://m.douban.com/rexxar/api/v2/\(kind)/\(id)")!
            guard let got = await get(url, referer: "https://m.douban.com/\(kind)/") else { return .failed }
            guard let d = got, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["id"] != nil else { continue }
            var rating: Double?
            if let r = j["rating"] as? [String: Any] { rating = (r["value"] as? NSNumber)?.doubleValue }
            let intro = (j["intro"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .found(DoubanInfo(id: id, rating: (rating ?? 0) > 0 ? rating : nil, intro: intro?.isEmpty == false ? intro : nil))
        }
        return .found(DoubanInfo(id: id, rating: nil, intro: nil))
    }

    private enum Search { case found(String), notFound, failed }
    private static func search(_ q: String, year: Int?, tv: Bool) async -> Search {
        var c = URLComponents(string: "https://movie.douban.com/j/subject_suggest")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let got = await get(c.url!, referer: "https://movie.douban.com/") else { return .failed }
        guard let d = got, let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return .notFound }
        let norm: (String) -> String = { $0.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation } }
        let nq = norm(q)
        var best: (String, Int)?
        for x in arr {
            guard (x["type"] as? String) == "movie", let id = x["id"] as? String else { continue }
            let t = x["title"] as? String ?? "", sub = x["sub_title"] as? String ?? ""
            let isTV = !((x["episode"] as? String) ?? "").isEmpty
            var s = 0
            if norm(t) == nq || norm(sub) == nq { s += 4 } else if norm(t).hasPrefix(nq) { s += 2 }
            if let y = year, let dy = Int(x["year"] as? String ?? "") {
                if dy == y { s += 4 } else if abs(dy - y) == 1 { s += 2 } else if !tv { s -= 4 }
            }
            if isTV == tv { s += 1 }
            if best == nil || s > best!.1 { best = (id, s) }
        }
        guard let b = best, b.1 >= 3 else { return .notFound }
        return .found(b.0)
    }
}

extension LibraryItem {
    var shownRating: Double? { MetaSource.douban && (dbRating ?? 0) > 0 ? dbRating : rating }
    var shownOverview: String? { MetaSource.douban && dbIntro?.isEmpty == false ? dbIntro : overview }
}
