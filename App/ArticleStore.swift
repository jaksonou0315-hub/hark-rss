import Foundation
import SwiftData

/// One cached article, stored with SwiftData.
@Model
final class ItemRecord {
    @Attribute(.unique) var key: String
    var title: String
    var link: String
    var summary: String
    var content: String
    var author: String
    var date: Date?
    var guid: String
    var source: String
    var sourceID: UUID?
    var imageURL: String
    var enclosureURL: String
    var enclosureType: String
    var categories: [String]
    var firstSeen: Date?

    init(_ i: FeedItem) {
        key = i.id; title = i.title; link = i.link; summary = i.summary; content = i.content
        author = i.author; date = i.date; guid = i.guid; source = i.source; sourceID = i.sourceID
        imageURL = i.imageURL; enclosureURL = i.enclosureURL; enclosureType = i.enclosureType
        categories = i.categories; firstSeen = i.firstSeen
    }

    func update(_ i: FeedItem) {
        if title != i.title { title = i.title }
        if summary != i.summary { summary = i.summary }
        if content != i.content { content = i.content }
        if date != i.date { date = i.date }
        if imageURL != i.imageURL { imageURL = i.imageURL }
        if enclosureURL != i.enclosureURL { enclosureURL = i.enclosureURL }
        if firstSeen != i.firstSeen { firstSeen = i.firstSeen }
    }

    var item: FeedItem {
        FeedItem(title: title, link: link, summary: summary, content: content, author: author, date: date,
                 guid: guid, source: source, sourceID: sourceID, imageURL: imageURL,
                 enclosureURL: enclosureURL, enclosureType: enclosureType, categories: categories,
                 firstSeen: firstSeen)
    }
}

@MainActor
enum ArticleStore {
    static let container: ModelContainer? = {
        let url = FeedStore.dataDir.appendingPathComponent("Articles.store")
        return try? ModelContainer(for: ItemRecord.self, configurations: ModelConfiguration(url: url))
    }()

    static func loadAll() -> [FeedItem]? {
        guard let ctx = container?.mainContext else { return nil }
        let d = FetchDescriptor<ItemRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        guard let rows = try? ctx.fetch(d), !rows.isEmpty else { return nil }
        return rows.map(\.item)
    }

    /// Makes the store match `items`: inserts new articles, updates changed ones, deletes the rest.
    static func sync(_ items: [FeedItem]) {
        guard let ctx = container?.mainContext else { return }
        let existing = (try? ctx.fetch(FetchDescriptor<ItemRecord>())) ?? []
        var byKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for i in items {
            if let r = byKey.removeValue(forKey: i.id) { r.update(i) } else { ctx.insert(ItemRecord(i)) }
        }
        for r in byKey.values { ctx.delete(r) }
        try? ctx.save()
    }
}
