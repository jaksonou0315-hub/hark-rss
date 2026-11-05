import Foundation

struct FeedItem: Identifiable, Hashable, Codable {
    var id: String { guid.isEmpty ? link + title : guid }
    var title: String
    var link: String
    var summary: String
    var date: Date?
    var guid: String
    var source: String
}

struct FeedSource: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
}

final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [FeedItem] = []
    private var cur: [String: String] = [:]
    private var text = ""
    private var inItem = false
    private var channelTitle = ""
    private let source: String
    init(source: String) { self.source = source }

    func parse(_ data: Data) -> (String, [FeedItem]) {
        let p = XMLParser(data: data); p.delegate = self; p.parse()
        return (channelTitle, items)
    }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        text = ""
        if e == "item" || e == "entry" { inItem = true; cur = [:] }
        if inItem && e == "link", let href = a["href"] { cur["link"] = href }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, foundCDATA d: Data) { text += String(data: d, encoding: .utf8) ?? "" }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch e {
            case "title": cur["title"] = t
            case "link": if !t.isEmpty { cur["link"] = t }
            case "description", "summary", "content", "content:encoded": if cur["summary"] == nil || e == "content:encoded" { cur["summary"] = t }
            case "pubDate", "published", "updated", "dc:date": if cur["date"] == nil { cur["date"] = t }
            case "guid", "id": cur["guid"] = t
            case "item", "entry":
                items.append(FeedItem(title: cur["title"] ?? "(无标题)", link: cur["link"] ?? "", summary: cur["summary"] ?? "",
                                      date: Self.date(cur["date"]), guid: cur["guid"] ?? "", source: source))
                inItem = false
            default: break
            }
        } else if e == "title" && channelTitle.isEmpty { channelTitle = t }
        text = ""
    }
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            f.dateFormat = fmt; if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }
}

@MainActor
final class FeedStore: ObservableObject {
    @Published var sources: [FeedSource] = [] { didSet { save() } }
    @Published var items: [FeedItem] = []
    @Published var readIDs: Set<String> = [] { didSet { UserDefaults.standard.set(Array(readIDs), forKey: "read") } }
    @Published var loading = false
    @Published var error: String?

    static let defaultFeed = "https://raw.githubusercontent.com/jaksonou0315-hub/hark-rss/main/feed.xml"

    init() {
        if let d = UserDefaults.standard.data(forKey: "sources"), let s = try? JSONDecoder().decode([FeedSource].self, from: d) { sources = s }
        if sources.isEmpty { sources = [FeedSource(name: "Hark 推送", url: Self.defaultFeed)] }
        readIDs = Set(UserDefaults.standard.stringArray(forKey: "read") ?? [])
        if let d = UserDefaults.standard.data(forKey: "cache"), let c = try? JSONDecoder().decode([FeedItem].self, from: d) { items = c }
    }
    private func save() { if let d = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(d, forKey: "sources") } }

    var unread: Int { items.filter { !readIDs.contains($0.id) }.count }

    func refresh() async {
        loading = true; error = nil
        var all: [FeedItem] = []
        for s in sources {
            guard let u = URL(string: s.url) else { continue }
            var req = URLRequest(url: u); req.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let (_, its) = RSSParser(source: s.name).parse(data); all += its
            } catch { self.error = "\(s.name)：\(error.localizedDescription)" }
        }
        if !all.isEmpty || error == nil {
            items = all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "cache") }
        }
        loading = false
    }
    func markAllRead() { readIDs.formUnion(items.map(\.id)) }
}
