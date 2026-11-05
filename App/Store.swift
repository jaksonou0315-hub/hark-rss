import Foundation
import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks

@MainActor
final class FeedStore: ObservableObject {
    static let shared = FeedStore()
    static let refreshTaskID = "com.ouyanghong.harkrss.refresh"

    enum Scope: Hashable { case all, group(String), source(UUID) }

    @Published var sources: [FeedSource] { didSet { persist(sources, "sources") } }
    @Published private(set) var items: [FeedItem] = []
    @Published var readIDs: Set<String> { didSet { persist(readIDs, "readIDs"); updateBadge() } }
    @Published var starredIDs: Set<String> { didSet { persist(starredIDs, "starredIDs") } }
    @Published var laterIDs: Set<String> { didSet { persist(laterIDs, "laterIDs") } }
    @Published var saved: [String: FeedItem] { didSet { persist(saved, "savedItems") } }
    @Published var rules: [FilterRule] { didSet { persist(rules, "rules") } }
    @Published var notify: Bool {
        didSet {
            UserDefaults.standard.set(notify, forKey: "notify")
            if notify { requestNotificationPermission() }
            updateBadge()
        }
    }
    @Published var refreshMinutes: Int {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); scheduleBackgroundRefresh() }
    }
    @Published var loading = false
    @Published var requestAddSource = false
    @Published var lastError: String?
    @Published var lastRefresh: Date?
    var fullText: [String: String] = [:]

    init() {
        let d = UserDefaults.standard
        sources = Self.load("sources", [FeedSource].self) ?? []
        readIDs = Self.load("readIDs", Set<String>.self) ?? Set(d.stringArray(forKey: "read") ?? [])
        starredIDs = Self.load("starredIDs", Set<String>.self) ?? []
        laterIDs = Self.load("laterIDs", Set<String>.self) ?? []
        saved = Self.load("savedItems", [String: FeedItem].self) ?? [:]
        rules = Self.load("rules", [FilterRule].self) ?? []
        notify = d.bool(forKey: "notify")
        let m = d.integer(forKey: "refreshMinutes")
        refreshMinutes = m == 0 ? 30 : m
        items = Self.load("itemCache", [FeedItem].self) ?? []
        if sources.isEmpty {
            sources = [FeedSource(name: "Hark 推送", url: FeedSource.defaultFeed, group: "Hark")]
            persist(sources, "sources")
        }
        if d.bool(forKey: "HarkDemo") {
            let demo = [("少数派", "https://sspai.com/feed", "科技"),
                        ("The Verge", "https://www.theverge.com/rss/index.xml", "科技"),
                        ("Apple Newsroom", "https://www.apple.com/newsroom/rss-feed.rss", "科技"),
                        ("阮一峰的网络日志", "https://www.ruanyifeng.com/blog/atom.xml", "博客"),
                        ("Planet Money", "https://feeds.npr.org/510289/podcast.xml", "播客")]
            for (n, u, g) in demo where !sources.contains(where: { $0.url == u }) {
                sources.append(FeedSource(name: n, url: u, group: g))
            }
            if rules.isEmpty { rules = [FilterRule(keyword: "AI", kind: .highlight), FilterRule(keyword: "广告", kind: .mute)] }
            persist(sources, "sources"); persist(rules, "rules")
        }
    }

    private func applyDemoState() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "HarkDemo") else { return }
        if starredIDs.isEmpty {
            for (n, i) in items.prefix(15).enumerated() {
                if n % 3 == 1 { saved[i.id] = i; starredIDs.insert(i.id) }
                if n % 4 == 2 { saved[i.id] = i; laterIDs.insert(i.id) }
                if n >= 5 && n % 2 == 0 { readIDs.insert(i.id) }
            }
        }
        if d.bool(forKey: "HarkPlay"), Player.shared.current == nil, let m = items.first(where: { $0.hasMedia && $0.isAudio }) {
            Player.shared.play(m)
        }
    }

    // MARK: persistence
    private func persist<T: Encodable>(_ v: T, _ k: String) {
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: k) }
    }
    private static func load<T: Decodable>(_ k: String, _ t: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: k) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: queries
    static func newest(_ a: FeedItem, _ b: FeedItem) -> Bool { (a.date ?? .distantPast) > (b.date ?? .distantPast) }

    var groups: [String] { Array(Set(sources.map(groupName))).sorted() }
    func groupName(_ s: FeedSource) -> String { s.group.isEmpty ? "未分组" : s.group }
    func isRead(_ i: FeedItem) -> Bool { readIDs.contains(i.id) }
    func isStarred(_ i: FeedItem) -> Bool { starredIDs.contains(i.id) }
    func isLater(_ i: FeedItem) -> Bool { laterIDs.contains(i.id) }
    func isMuted(_ i: FeedItem) -> Bool { rules.contains { $0.kind == .mute && matches($0, i) } }
    func isHighlighted(_ i: FeedItem) -> Bool { rules.contains { $0.kind == .highlight && matches($0, i) } }
    private func matches(_ r: FilterRule, _ i: FeedItem) -> Bool {
        let k = r.keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return false }
        return i.title.localizedCaseInsensitiveContains(k) || i.summary.localizedCaseInsensitiveContains(k)
    }

    func timeline(scope: Scope) -> [FeedItem] {
        let enabled = Set(sources.filter(\.enabled).map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        return items.filter { i in
            if isMuted(i) { return false }
            if let sid = i.sourceID, !enabled.contains(sid) { return false }
            switch scope {
            case .all: return true
            case .group(let g): return i.sourceID.flatMap { byID[$0] }.map { groupName($0) == g } ?? false
            case .source(let id): return i.sourceID == id
            }
        }
    }
    var starredItems: [FeedItem] { starredIDs.compactMap { id in items.first { $0.id == id } ?? saved[id] }.sorted(by: Self.newest) }
    var laterItems: [FeedItem] { laterIDs.compactMap { id in items.first { $0.id == id } ?? saved[id] }.sorted(by: Self.newest) }
    var unreadTotal: Int { timeline(scope: .all).filter { !isRead($0) }.count }
    func unreadCount(for s: FeedSource) -> Int { items.filter { $0.sourceID == s.id && !isRead($0) && !isMuted($0) }.count }

    // MARK: mutations
    func markRead(_ i: FeedItem) { if !readIDs.contains(i.id) { readIDs.insert(i.id) } }
    func toggleRead(_ i: FeedItem) { if isRead(i) { readIDs.remove(i.id) } else { readIDs.insert(i.id) } }
    func markAllRead(_ list: [FeedItem]) { readIDs.formUnion(list.map(\.id)) }
    func toggleStar(_ i: FeedItem) {
        if isStarred(i) { starredIDs.remove(i.id) } else { saved[i.id] = i; starredIDs.insert(i.id) }
    }
    func toggleLater(_ i: FeedItem) {
        if isLater(i) { laterIDs.remove(i.id) } else { saved[i.id] = i; laterIDs.insert(i.id) }
    }
    func addSource(name: String, url: String, group: String) {
        guard !sources.contains(where: { $0.url == url }) else { return }
        sources.append(FeedSource(name: name.isEmpty ? url : name, url: url, group: group))
    }
    func updateSource(_ s: FeedSource) {
        if let idx = sources.firstIndex(where: { $0.id == s.id }) { sources[idx] = s }
    }
    func removeSource(_ s: FeedSource) {
        sources.removeAll { $0.id == s.id }
        items.removeAll { $0.sourceID == s.id }
        persist(items, "itemCache")
    }
    func clearCache() { items = []; persist(items, "itemCache"); fullText = [:] }

    // MARK: refresh
    @discardableResult
    func refresh(notifying: Bool = false) async -> Int {
        if loading { return 0 }
        loading = true
        let list = sources.filter(\.enabled)
        var fetched: [FeedItem] = []
        var errors: [String] = []
        var failed = Set<UUID>()
        await withTaskGroup(of: (FeedSource, Result<[FeedItem], Error>).self) { g in
            for s in list { g.addTask { (s, await Self.fetch(s)) } }
            for await (s, r) in g {
                switch r {
                case .success(let its): fetched += its
                case .failure(let e): errors.append("\(s.name)：\(e.localizedDescription)"); failed.insert(s.id)
                }
            }
        }
        let old = Set(items.map(\.id))
        let kept = items.filter { i in i.sourceID.map { failed.contains($0) } ?? false }
        var seen = Set<String>()
        var merged: [FeedItem] = []
        for i in (fetched + kept).sorted(by: Self.newest) where seen.insert(i.id).inserted { merged.append(i) }
        let newOnes = merged.filter { !old.contains($0.id) && !readIDs.contains($0.id) && !isMuted($0) }
        items = merged
        persist(items, "itemCache")
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        lastRefresh = Date()
        loading = false
        updateBadge()
        applyDemoState()
        if notifying && !old.isEmpty { postNotification(newOnes) }
        return newOnes.count
    }

    nonisolated static func fetch(_ s: FeedSource) async -> Result<[FeedItem], Error> {
        guard let u = URL(string: s.url) else { return .failure(URLError(.badURL)) }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("HarkRSS/2.0 (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return .success(FeedParser.parse(data, source: s).1)
        } catch {
            return .failure(error)
        }
    }

    func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        await refresh(notifying: true)
    }

    func scheduleBackgroundRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: Double(refreshMinutes) * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    // MARK: notifications
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    private func postNotification(_ new: [FeedItem]) {
        guard notify, !new.isEmpty else { return }
        let c = UNMutableNotificationContent()
        c.title = new.count == 1 ? new[0].source : "\(new.count) 条新消息"
        c.body = new.prefix(3).map(\.title).joined(separator: "\n")
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
    func updateBadge() {
        let n = notify ? unreadTotal : 0
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
        } else {
            UIApplication.shared.applicationIconBadgeNumber = n
        }
    }

    // MARK: OPML
    func exportOPML() -> String {
        func esc(_ s: String) -> String { s.escapedHTML }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n<head><title>Hark 推送订阅</title></head>\n<body>\n"
        for g in groups {
            out += "  <outline text=\"\(esc(g))\" title=\"\(esc(g))\">\n"
            for s in sources where groupName(s) == g {
                out += "    <outline type=\"rss\" text=\"\(esc(s.name))\" title=\"\(esc(s.name))\" xmlUrl=\"\(esc(s.url))\"/>\n"
            }
            out += "  </outline>\n"
        }
        return out + "</body>\n</opml>\n"
    }
    func importOPML(_ data: Data) -> Int {
        let existing = Set(sources.map(\.url))
        let new = OPMLParser().parse(data).filter { !existing.contains($0.url) }
        sources += new
        return new.count
    }
}
