import Foundation

struct FeedItem: Identifiable, Hashable, Codable {
    var id: String { guid.isEmpty ? link + title : guid }
    var title: String
    var link: String
    var summary: String
    var content: String = ""
    var author: String = ""
    var date: Date?
    var guid: String
    var source: String
    var sourceID: UUID?
    var imageURL: String = ""
    var enclosureURL: String = ""
    var enclosureType: String = ""
    var categories: [String] = []
    var firstSeen: Date? = nil

    var plainSummary: String { summary.strippingHTML }
    var isAudio: Bool {
        let u = enclosureURL.lowercased()
        return enclosureType.hasPrefix("audio") || u.hasSuffix(".mp3") || u.hasSuffix(".m4a") || u.hasSuffix(".aac")
    }
    var isVideo: Bool {
        let u = enclosureURL.lowercased()
        return enclosureType.hasPrefix("video") || u.hasSuffix(".mp4") || u.hasSuffix(".m3u8") || u.hasSuffix(".mov")
    }
    var hasMedia: Bool { !enclosureURL.isEmpty && (isAudio || isVideo) }
}

/// Per-feed fetch status, shown on the 订阅 tab.
struct SourceHealth: Codable, Hashable {
    var etag: String?
    var lastModified: String?
    var lastAttempt: Date?
    var lastSuccess: Date?
    var newest: Date?
    var error: String?
    var count: Int?

    enum State { case ok, stale, failing, unknown }
    var state: State {
        if error != nil { return .failing }
        guard lastSuccess != nil else { return .unknown }
        if let n = newest, n < Date().addingTimeInterval(-30 * 86400) { return .stale }
        return .ok
    }
}

struct FeedSource: Identifiable, Codable, Hashable {
    static let defaultFeed = "https://raw.githubusercontent.com/jaksonou0315-hub/hark-rss/main/feed.xml"

    var id = UUID()
    var name: String
    var url: String
    var group: String = ""
    var enabled: Bool = true

    init(id: UUID = UUID(), name: String, url: String, group: String = "", enabled: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.group = group; self.enabled = enabled
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct FilterRule: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case mute, highlight
        var label: String { self == .mute ? "屏蔽" : "高亮" }
    }
    var id = UUID()
    var keyword: String
    var kind: Kind
}

extension String {
    var strippingHTML: String {
        var s = replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&amp;": "&"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = s.decodingNumericEntities
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Decodes &#038; / &#x26; style entities.
    var decodingNumericEntities: String {
        guard contains("&#") else { return self }
        let re = try! NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);")
        let ns = self as NSString
        var out = ""; var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)).isEmpty == false
            let num = ns.substring(with: m.range(at: 2))
            if let v = UInt32(num, radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            else { out += ns.substring(with: m.range) }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
    var escapedHTML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    var firstImageURL: String? {
        guard let r = range(of: "<img[^>]+src=[\"'][^\"']+[\"']", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tag = String(self[r])
        guard let r2 = tag.range(of: "src=[\"'][^\"']+", options: .regularExpression) else { return nil }
        let v = String(tag[r2].dropFirst(5)).replacingOccurrences(of: "&amp;", with: "&")
        return v.hasPrefix("http") ? v : nil
    }
}
