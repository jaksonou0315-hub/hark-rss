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
    @Published var health: [UUID: SourceHealth] { didSet { persist(health, "health") } }
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays"); pruneNow() }
    }
    @Published var loading = false
    @Published var requestAddSource = UserDefaults.standard.bool(forKey: "HarkShowAdd")
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
        health = Self.load("health", [UUID: SourceHealth].self) ?? [:]
        retentionDays = d.object(forKey: "retentionDays") == nil ? 30 : d.integer(forKey: "retentionDays")
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
    /// Data lives in JSON files under Application Support, written off the main thread.
    /// Older builds kept it in UserDefaults; it is migrated on first read.
    private static let ioQueue = DispatchQueue(label: "harkrss.io", qos: .utility)
    private static var pending: [String: DispatchWorkItem] = [:]
    static var dataDir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarkRSS", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static func file(_ k: String) -> URL { dataDir.appendingPathComponent(k + ".json") }

    private func persist<T: Encodable>(_ v: T, _ k: String) {
        Self.pending[k]?.cancel()
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(v) else { return }
            try? data.write(to: Self.file(k), options: .atomic)
        }
        Self.pending[k] = work
        Self.ioQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    private static func load<T: Decodable>(_ k: String, _ t: T.Type) -> T? {
        if let data = try? Data(contentsOf: file(k)) { return try? JSONDecoder().decode(T.self, from: data) }
        guard let data = UserDefaults.standard.data(forKey: k) else { return nil }
        try? data.write(to: file(k), options: .atomic)
        UserDefaults.standard.removeObject(forKey: k)
        return try? JSONDecoder().decode(T.self, from: data)
    }
    var dataSize: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.dataDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
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
        health[s.id] = nil
        items.removeAll { $0.sourceID == s.id }
        persist(items, "itemCache")
    }
    func clearCache() { items = []; persist(items, "itemCache"); fullText = [:]; health = [:] }

    /// Drops articles older than the retention window. Starred and read-later items are always kept.
    private func pruned(_ list: [FeedItem]) -> [FeedItem] {
        let keep = starredIDs.union(laterIDs)
        let ids = Set(sources.map(\.id))
        let cutoff = retentionDays > 0 ? Date().addingTimeInterval(-Double(retentionDays) * 86400) : nil
        var out = list.filter { i in
            if keep.contains(i.id) { return true }
            if let sid = i.sourceID, !ids.contains(sid) { return false }
            guard let cutoff else { return true }
            return (i.date ?? i.firstSeen ?? Date()) >= cutoff
        }
        if out.count > 4000 { out = Array(out.prefix(4000)) }
        return out
    }
    func pruneNow() {
        let p = pruned(items)
        guard p.count != items.count else { return }
        items = p
        persist(items, "itemCache")
        let alive = Set(p.map(\.id)).union(saved.keys)
        let r = readIDs.intersection(alive)
        if r.count != readIDs.count { readIDs = r }
    }

    // MARK: refresh
    @discardableResult
    func refresh(notifying: Bool = false) async -> Int {
        if loading { return 0 }
        loading = true
        let list = sources.filter(\.enabled)
        let cached = Set(items.compactMap(\.sourceID))
        let h0 = health
        var results: [(FeedSource, FetchResult)] = []
        // At most 6 feeds in flight; conditional GET when we already hold that feed's items.
        await withTaskGroup(of: (FeedSource, FetchResult).self) { g in
            var idx = 0
            while idx < min(6, list.count) {
                let s = list[idx]; idx += 1
                let e = cached.contains(s.id) ? h0[s.id] : nil
                g.addTask { (s, await Self.fetch(s, etag: e?.etag, lastModified: e?.lastModified)) }
            }
            while let r = await g.next() {
                results.append(r)
                if idx < list.count {
                    let s = list[idx]; idx += 1
                    let e = cached.contains(s.id) ? h0[s.id] : nil
                    g.addTask { (s, await Self.fetch(s, etag: e?.etag, lastModified: e?.lastModified)) }
                }
            }
        }
        var h = health
        var fresh: [FeedItem] = []
        var errors: [String] = []
        let now = Date()
        for (s, r) in results {
            var x = h[s.id] ?? SourceHealth()
            x.lastAttempt = now
            switch r {
            case .items(let its, let et, let lm):
                fresh += its
                x.etag = et; x.lastModified = lm; x.lastSuccess = now; x.error = nil
                if let n = its.compactMap(\.date).max() { x.newest = n }
                x.count = its.count
            case .notModified:
                x.lastSuccess = now; x.error = nil
            case .failed(let m):
                x.error = m
                errors.append("\(s.name)：\(m)")
            }
            h[s.id] = x
        }
        health = h
        var oldSeen: [String: Date] = [:]
        for i in items { oldSeen[i.id] = i.firstSeen ?? i.date ?? now }
        let old = Set(oldSeen.keys)
        var seen = Set<String>()
        var merged: [FeedItem] = []
        for var i in fresh + items {
            let id = i.id
            guard seen.insert(id).inserted else { continue }
            i.firstSeen = oldSeen[id] ?? now
            merged.append(i)
        }
        merged.sort(by: Self.newest)
        merged = pruned(merged)
        let newOnes = merged.filter { !old.contains($0.id) && !readIDs.contains($0.id) && !isMuted($0) }
        items = merged
        persist(items, "itemCache")
        let alive = Set(merged.map(\.id)).union(saved.keys)
        let r = readIDs.intersection(alive)
        if r.count != readIDs.count { readIDs = r }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        lastRefresh = now
        loading = false
        updateBadge()
        applyDemoState()
        if notifying && !old.isEmpty { postNotification(newOnes) }
        return newOnes.count
    }

    enum FetchResult { case items([FeedItem], String?, String?), notModified, failed(String) }

    nonisolated static func fetch(_ s: FeedSource, etag: String? = nil, lastModified: String? = nil) async -> FetchResult {
        guard let u = URL(string: s.url) else { return .failed("地址无效") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("HarkRSS/2.3 (iOS)", forHTTPHeaderField: "User-Agent")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 304 { return .notModified }
            if let c = http?.statusCode, c >= 400 { return .failed("服务器返回 \(c)") }
            let its = FeedParser.parse(data, source: s).1
            if its.isEmpty && FeedDiscovery.looksLikeFeed(data, url: s.url) == nil { return .failed("不是有效的订阅源") }
            return .items(its, http?.value(forHTTPHeaderField: "ETag"), http?.value(forHTTPHeaderField: "Last-Modified"))
        } catch {
            return .failed(error.localizedDescription)
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
