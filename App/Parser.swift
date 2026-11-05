import Foundation

enum FeedParser {
    static func parse(_ data: Data, source: FeedSource) -> (String, [FeedItem]) {
        let ws: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09, 0xEF, 0xBB, 0xBF]
        if data.prefix(64).first(where: { !ws.contains($0) }) == UInt8(ascii: "{") {
            return parseJSON(data, source: source)
        }
        return XMLFeedParser(source: source).parse(data)
    }

    static func parseJSON(_ data: Data, source: FeedSource) -> (String, [FeedItem]) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ("", []) }
        let title = o["title"] as? String ?? ""
        let arr = o["items"] as? [[String: Any]] ?? []
        var out: [FeedItem] = []
        for j in arr {
            var it = FeedItem(title: j["title"] as? String ?? "", link: j["url"] as? String ?? "",
                              summary: j["summary"] as? String ?? (j["content_text"] as? String ?? ""),
                              date: XMLFeedParser.date(j["date_published"] as? String),
                              guid: j["id"].map { "\($0)" } ?? "", source: source.name)
            it.sourceID = source.id
            it.content = j["content_html"] as? String ?? ""
            if let authors = j["authors"] as? [[String: Any]] {
                it.author = authors.compactMap { $0["name"] as? String }.joined(separator: ", ")
            }
            it.imageURL = j["image"] as? String ?? (j["banner_image"] as? String ?? "")
            if let att = (j["attachments"] as? [[String: Any]])?.first {
                it.enclosureURL = att["url"] as? String ?? ""
                it.enclosureType = att["mime_type"] as? String ?? ""
            }
            it.categories = j["tags"] as? [String] ?? []
            if it.summary.isEmpty { it.summary = it.content }
            it.title = it.title.strippingHTML
            if it.title.isEmpty { let s = it.summary.strippingHTML; it.title = s.isEmpty ? "(无标题)" : String(s.prefix(60)) }
            if it.imageURL.isEmpty { it.imageURL = (it.content.isEmpty ? it.summary : it.content).firstImageURL ?? "" }
            out.append(it)
        }
        return (title, out)
    }
}

final class XMLFeedParser: NSObject, XMLParserDelegate {
    private let source: FeedSource
    private var items: [FeedItem] = []
    private var cur: FeedItem?
    private var text = ""
    private var channelTitle = ""
    private var inAuthor = false
    private var inChannelImage = false

    init(source: FeedSource) { self.source = source }

    func parse(_ data: Data) -> (String, [FeedItem]) {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return (channelTitle, items)
    }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        text = ""
        switch e {
        case "item", "entry":
            var i = FeedItem(title: "", link: "", summary: "", date: nil, guid: "", source: source.name)
            i.sourceID = source.id
            cur = i
        case "author": inAuthor = true
        case "image": if cur == nil { inChannelImage = true }
        default: break
        }
        guard var c = cur else { return }
        switch e {
        case "link":
            if let href = a["href"] {
                let rel = a["rel"] ?? "alternate"
                if rel == "enclosure" {
                    c.enclosureURL = href; c.enclosureType = a["type"] ?? ""
                } else if rel == "alternate" && c.link.isEmpty {
                    c.link = href
                }
            }
        case "enclosure", "media:content":
            if let u = a["url"] {
                let t = a["type"] ?? a["medium"] ?? ""
                if t.hasPrefix("image") {
                    if c.imageURL.isEmpty { c.imageURL = u }
                } else if (t.hasPrefix("audio") || t.hasPrefix("video") || e == "enclosure") && c.enclosureURL.isEmpty {
                    c.enclosureURL = u; c.enclosureType = t
                }
            }
        case "media:thumbnail", "itunes:image":
            if let u = a["url"] ?? a["href"], c.imageURL.isEmpty { c.imageURL = u }
        case "category":
            if let t = a["term"] { c.categories.append(t) }
        default: break
        }
        cur = c
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, foundCDATA d: Data) { text += String(decoding: d, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        if e == "author" { inAuthor = false }
        if e == "image" { inChannelImage = false }
        guard var c = cur else {
            if e == "title" && channelTitle.isEmpty && !inChannelImage { channelTitle = t }
            return
        }
        switch e {
        case "title": if c.title.isEmpty { c.title = t }
        case "link": if c.link.isEmpty && !t.isEmpty { c.link = t }
        case "description", "summary", "media:description": if c.summary.isEmpty { c.summary = t }
        case "content:encoded", "content": if !t.isEmpty { c.content = t }
        case "pubDate", "published", "dc:date": c.date = Self.date(t) ?? c.date
        case "updated": if c.date == nil { c.date = Self.date(t) }
        case "guid", "id": if c.guid.isEmpty { c.guid = t }
        case "dc:creator", "itunes:author": if c.author.isEmpty { c.author = t }
        case "name": if inAuthor && c.author.isEmpty { c.author = t }
        case "author": if c.author.isEmpty && !t.isEmpty && !t.contains("\n") { c.author = t }
        case "category": if !t.isEmpty { c.categories.append(t) }
        case "item", "entry":
            if c.summary.isEmpty { c.summary = c.content }
            c.title = c.title.strippingHTML
            if c.title.isEmpty { let s = c.summary.strippingHTML; c.title = s.isEmpty ? "(无标题)" : String(s.prefix(60)) }
            if c.imageURL.isEmpty { c.imageURL = (c.content.isEmpty ? c.summary : c.content).firstImageURL ?? "" }
            items.append(c)
            cur = nil
            return
        default: break
        }
        cur = c
    }

    static let formats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                          "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z",
                          "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]

    static func date(_ raw: String?) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

final class OPMLParser: NSObject, XMLParserDelegate {
    private var stack: [String?] = []
    private var out: [FeedSource] = []

    func parse(_ d: Data) -> [FeedSource] {
        let p = XMLParser(data: d)
        p.delegate = self
        p.parse()
        return out
    }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        guard e == "outline" else { return }
        let title = a["title"] ?? a["text"] ?? ""
        if let url = a["xmlUrl"] ?? a["xmlurl"], !url.isEmpty {
            let group = stack.compactMap { $0 }.last ?? ""
            out.append(FeedSource(name: title.isEmpty ? url : title, url: url, group: group))
            stack.append(nil)
        } else {
            stack.append(title)
        }
    }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        if e == "outline" && !stack.isEmpty { stack.removeLast() }
    }
}
