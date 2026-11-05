import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Makes starred and read-later articles findable from system search.
enum Spotlight {
    static let domain = "com.ouyanghong.harkrss.saved"

    static func index(_ items: [FeedItem]) {
        let entries: [CSSearchableItem] = items.prefix(500).map { i in
            let a = CSSearchableItemAttributeSet(contentType: UTType.text)
            a.title = i.title
            a.displayName = i.title
            a.contentDescription = i.source + " · " + String(i.plainSummary.prefix(240))
            a.keywords = [i.source, "Hark"] + i.categories
            return CSSearchableItem(uniqueIdentifier: i.id, domainIdentifier: domain, attributeSet: a)
        }
        let idx = CSSearchableIndex.default()
        idx.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            guard !entries.isEmpty else { return }
            idx.indexSearchableItems(entries) { _ in }
        }
    }
}
