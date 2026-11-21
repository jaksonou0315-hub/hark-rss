import Foundation
import SwiftUI

struct LibraryFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var sourceId: UUID
    var dir: RemoteFile
    var title: String
}

struct LibraryFile: Codable, Identifiable, Hashable {
    var id: String
    var sourceId: UUID
    var file: RemoteFile
    var season: Int?
    var episode: Int?
    var subtitles: [RemoteFile] = []
    var episodeTitle: String?
    var still: URL?
}

struct LibraryItem: Codable, Identifiable, Hashable {
    var id: String
    var kind: String              // movie | tv
    var title: String
    var originalTitle: String?
    var year: Int?
    var overview: String?
    var poster: URL?
    var backdrop: URL?
    var rating: Double?
    var tmdbId: Int?
    var genres: [String]? = nil
    var certification: String? = nil
    var countries: [String]? = nil
    var files: [LibraryFile]
    var added = Date()

    var isTV: Bool { kind == "tv" }
    var seasons: [Int] { Array(Set(files.compactMap { $0.season })).sorted() }
    func episodes(season: Int?) -> [LibraryFile] {
        files.filter { $0.season == season }.sorted { ($0.episode ?? 0, $0.file.name) < ($1.episode ?? 0, $1.file.name) }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    @Published var folders: [LibraryFolder] = []
    @Published var items: [LibraryItem] = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var lastResult: String?
    @Published var lastScan: Date? = UserDefaults.standard.object(forKey: "lib.lastScan") as? Date
    private var rescanPending = false
    private var pendingForce = false
    @Published var scanFound = 0          // video files found so far
    @Published var scanDone = 0           // files fully processed (in library + matched)
    @Published var foldersLeft = 0
    @Published var matching = false
    var countLine: String? {
        guard scanning else { return nil }
        return "已找到 \(scanFound) 个文件，已完成 \(min(scanDone, scanFound)) 个，剩余 \(max(0, scanFound - scanDone)) 个"
    }
    private var enriching = false

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    private struct Snapshot: Codable { var folders: [LibraryFolder]; var items: [LibraryItem] }

    private init() {
        if let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Snapshot.self, from: d) {
            folders = s.folders; items = s.items
        }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(Snapshot(folders: folders, items: items)) { try? d.write(to: fileURL, options: .atomic) }
    }

    var movies: [LibraryItem] { items.filter { !$0.isTV }.sorted { $0.added > $1.added } }
    var shows: [LibraryItem] { items.filter { $0.isTV }.sorted { $0.added > $1.added } }

    func addFolder(source: MediaSource, dir: RemoteFile) {
        guard !folders.contains(where: { $0.sourceId == source.id && $0.dir.id == dir.id }) else { return }
        folders.append(LibraryFolder(sourceId: source.id, dir: dir, title: "\(source.name) · \(dir.name)"))
        save()
        Task { await scan() }
    }

    /// Whole drive as one library folder (used by 自动扫描).
    func addRoot(source: MediaSource) {
        guard !folders.contains(where: { $0.sourceId == source.id && $0.dir.meta["root"] == "1" }) else { return }
        var root = RemoteFile(id: "__root__", name: source.name, path: "", isDir: true)
        root.meta["root"] = "1"
        folders.append(LibraryFolder(sourceId: source.id, dir: root, title: "\(source.name) · 全部"))
        save()
        Task { await scan() }
    }

    func removeFolder(_ f: LibraryFolder) {
        folders.removeAll { $0.id == f.id }
        items = items.compactMap { item in
            var i = item
            i.files.removeAll { $0.sourceId == f.sourceId && $0.id.hasPrefix(f.sourceId.uuidString + ":") && isUnder($0, f) }
            return i.files.isEmpty ? nil : i
        }
        save()
    }

    private func isUnder(_ lf: LibraryFile, _ folder: LibraryFolder) -> Bool {
        lf.file.meta["folder"] == folder.id.uuidString
    }

    func clear() { items = []; save() }

    /// Source deleted: drop its library folders and every file that came from it.
    func removeSource(_ id: UUID) {
        folders.removeAll { $0.sourceId == id }
        items = items.compactMap { it in
            var i = it
            i.files.removeAll { $0.sourceId == id }
            return i.files.isEmpty ? nil : i
        }
        save()
    }

    private func precachePosters(_ list: [LibraryItem]) {
        let off = Set(SourceStore.shared.sources.filter { $0.extra["posterCache"] == "0" }.map(\.id))
        let urls = list.filter { !$0.files.allSatisfy { off.contains($0.sourceId) } }.flatMap { [$0.poster, $0.backdrop] }.compactMap { $0 }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .background) {
            for chunk in stride(from: 0, to: urls.count, by: 6).map({ Array(urls[$0..<min($0 + 6, urls.count)]) }) {
                await withTaskGroup(of: Void.self) { g in
                    for u in chunk {
                        g.addTask {
                            let r = URLRequest(url: u)
                            if URLCache.shared.cachedResponse(for: r) == nil { _ = try? await URLSession.shared.data(for: r) }
                        }
                    }
                }
            }
        }
    }

    /// Fills genres / certification / countries for matched items that don't have them yet.
    func enrich() async {
        guard !enriching else { return }
        enriching = true
        defer { enriching = false }
        let srcs = SourceStore.shared.sources
        let prefetchOff = Set(srcs.filter { $0.extra["prefetch"] == "0" }.map(\.id))
        let todo = items.filter { it in
            it.tmdbId != nil && (it.certification == nil || it.genres == nil)
                && !(it.files.allSatisfy { prefetchOff.contains($0.sourceId) })
        }
        var changed = 0
        for it in todo {
            await AppActivity.shared.waitUntilActive()
            guard let id = it.tmdbId, let d = await TMDB.details(id: id, tv: it.isTV) else { continue }
            guard let i = items.firstIndex(where: { $0.id == it.id }) else { continue }
            if !d.genres.isEmpty { items[i].genres = d.genres }
            items[i].certification = d.certification ?? ""
            items[i].countries = d.countries
            changed += 1
            if changed % 20 == 0 { save() }
        }
        if changed > 0 { save() }
        TMDBCache.shared.flush()
    }

    // MARK: scanning


    /// force = list every folder now (重新扫描文件); otherwise a delta pass that only lists dirs past their TTL.
    func scan(force: Bool = true) async {
        if scanning { rescanPending = true; pendingForce = pendingForce || force; return }
        var f = force
        repeat {
            rescanPending = false
            await scanOnce(force: f)
            f = pendingForce; pendingForce = false
        } while rescanPending
    }

    private var crawlActive = false
    private var matchTried = Set<String>()
    /// New items still waiting for their poster: kept out of the library until matched (or the match fails).
    private var staged: [String: LibraryItem] = [:]
    private var stagedOrder: [String] = []
    private var knownIds = Set<String>()
    private var inMatch: String?

    /// Split freshly built items: anything already shown, matched, or with a server poster goes in;
    /// brand-new unmatched ones wait in `staged` until matchLoop has tried them.
    private func publish(_ built: [LibraryItem], keepMissing: Bool) {
        var visible: [LibraryItem] = []
        for it in built {
            let ready = it.tmdbId != nil || it.poster != nil || knownIds.contains(it.id) || (matchTried.contains(it.id) && inMatch != it.id)
            if ready { visible.append(it); staged[it.id] = nil }
            else {
                if staged[it.id] == nil { stagedOrder.append(it.id) }
                staged[it.id] = it
            }
        }
        if keepMissing {
            let have = Set(built.map(\.id))
            visible += items.filter { !have.contains($0.id) }          // nothing disappears mid-scan
        }
        // keep current order for items already shown so shelves don't jump around
        let pos = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        items = visible.sorted { (pos[$0.id] ?? Int.max) < (pos[$1.id] ?? Int.max) }
        refreshCounts()
    }

    private func scanOnce(force: Bool) async {
        scanning = true
        scanFound = 0; scanDone = 0; foldersLeft = 0; matching = true
        crawlActive = true
        matchTried = []
        staged = [:]; stagedOrder = []
        knownIds = Set(items.map(\.id))
        defer { scanning = false; matching = false; crawlActive = false; progress = "" }
        let before = Set(items.flatMap { $0.files.map(\.id) })
        let folderSnapshot = folders

        // show videos as soon as their folder is read, and match posters while the crawl goes on
        let publisher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let f = ScanCenter.shared.snapshotFound(folderSnapshot)
                let (built, _) = self.buildItems(f, current: self.items + Array(self.staged.values))
                self.publish(built, keepMissing: true)
            }
        }
        let matcher = Task { @MainActor [weak self] in await self?.matchLoop() }

        let outcome = await ScanCenter.shared.collect(folders, force: force, counts: { [weak self] found, left in
            self?.foldersLeft = left
            if let self, found > self.scanFound { self.scanFound = found }
        }) { [weak self] msg in self?.progress = msg }
        publisher.cancel()
        let errors = outcome.errors
        let failedFolders = outcome.failedFolders

        let current = items + Array(staged.values)
        var (newItems, _) = buildItems(outcome.found, current: current)
        let old = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // keep what we already had from folders that could not be fully read this time (rate limits etc.)
        if !failedFolders.isEmpty {
            let have = Set(newItems.flatMap { $0.files.map(\.id) })
            for prev in old.values {
                let keep = prev.files.filter { failedFolders.contains($0.file.meta["folder"] ?? "") && !have.contains($0.id) }
                guard !keep.isEmpty else { continue }
                if let i = newItems.firstIndex(where: { $0.id == prev.id }) { newItems[i].files += keep }
                else { var p = prev; p.files = keep; newItems.append(p) }
            }
        }
        let newFileCount = Set(newItems.flatMap { $0.files.map(\.id) }).subtracting(before).count
        staged = [:]; stagedOrder = []
        publish(newItems, keepMissing: false)
        lastScan = Date()
        UserDefaults.standard.set(lastScan, forKey: "lib.lastScan")
        save()
        if newItems.isEmpty {
            lastResult = errors.first.map { "扫描失败：\($0)" } ?? (folders.isEmpty ? nil : "没在这些文件夹里找到视频文件")
        } else {
            lastResult = "扫描完成：\(newItems.count) 部影片，新增 \(newFileCount) 个文件" + (errors.isEmpty ? "" : "（\(errors.count) 个文件夹读取失败）")
        }

        // phase 2: TMDB only for what isn't matched yet (new / renamed), plus missing episode titles
        crawlActive = false
        progress = ""
        await matcher.value
        TMDBCache.shared.flush()
        Task { await enrich() }
        precachePosters(items)
    }

    /// Group found videos into library items, keeping whatever metadata `current` already has.
    private func buildItems(_ found: [ScanFound], current: [LibraryItem]) -> ([LibraryItem], Int) {
        // group
        struct ScanGroup { var parsed: ParsedName; var files: [LibraryFile]; var serverPoster: URL?; var serverOverview: String? }
        var groups: [String: ScanGroup] = [:]
        var order: [String] = []
        for f in found {
            var p: ParsedName
            if let series = f.file.meta["series"] {          // Emby/Jellyfin episode
                p = ParsedName(title: series, year: nil, season: f.file.meta["season"].flatMap { Int($0) }, episode: f.file.meta["episode"].flatMap { Int($0) })
            } else if f.file.meta["type"] == "Movie" {
                p = ParsedName(title: f.file.name, year: f.file.year, season: nil, episode: nil)
            } else if let t = f.titleOverride {             // BDMV / VIDEO_TS: the folder is the movie
                p = NameParser.parse(t + ".mkv", parents: Array(f.parents.dropFirst()))
                p.season = nil; p.episode = nil
            } else {
                p = NameParser.parse(f.file.name, parents: f.parents)
            }
            let key = (p.isEpisode ? "tv:" : "movie:") + p.title.lowercased() + (p.isEpisode ? "" : ":\(p.year ?? 0)")
            let lf = LibraryFile(id: f.source.id.uuidString + ":" + f.file.id, sourceId: f.source.id, file: f.file,
                                 season: p.season, episode: p.episode, subtitles: f.subs)
            if groups[key] == nil { groups[key] = ScanGroup(parsed: p, files: [], serverPoster: f.file.posterURL, serverOverview: f.file.overview); order.append(key) }
            groups[key]?.files.append(lf)
        }

        // put every file in the library right away (no network), reusing what earlier scans matched
        let old = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newItems: [LibraryItem] = []
        var newFileCount = 0
        for key in order {
            guard let g = groups[key] else { continue }
            let isTV = g.parsed.isEpisode
            var item = LibraryItem(id: key, kind: isTV ? "tv" : "movie", title: g.parsed.title, year: g.parsed.year,
                                   overview: g.serverOverview, poster: g.serverPoster, files: g.files)
            if let prev = old[key] {
                let prevIds = Set(prev.files.map(\.id))
                let fresh = g.files.filter { !prevIds.contains($0.id) }.count
                item.added = fresh > 0 ? Date() : prev.added      // new episodes move the show to the front of 最近添加
                newFileCount += fresh
                if prev.tmdbId != nil {
                    item.title = prev.title; item.originalTitle = prev.originalTitle; item.year = prev.year; item.overview = prev.overview
                    item.poster = prev.poster; item.backdrop = prev.backdrop; item.rating = prev.rating; item.tmdbId = prev.tmdbId
                    item.kind = prev.kind
                    item.genres = prev.genres; item.certification = prev.certification; item.countries = prev.countries
                    for i in item.files.indices {
                        if let pf = prev.files.first(where: { $0.id == item.files[i].id }) {
                            item.files[i].episodeTitle = pf.episodeTitle; item.files[i].still = pf.still
                        }
                    }
                }
            } else {
                newFileCount += g.files.count
            }
            newItems.append(item)
        }
        return (newItems, newFileCount)
    }

    /// Move a staged item into the library (matched, or TMDB had nothing for it).
    private func reveal(_ id: String) {
        if let it = staged.removeValue(forKey: id) {
            stagedOrder.removeAll { $0 == id }
            if let j = items.firstIndex(where: { $0.id == it.id }) { items[j] = it } else { items.insert(it, at: 0) }
        }
        refreshCounts()
    }

    private func needsMatch(_ it: LibraryItem) -> Bool {
        it.tmdbId == nil || (it.isTV && it.files.contains { $0.episodeTitle == nil && $0.episode != nil })
    }

    private func refreshCounts() {
        let stagedFiles = staged.values.reduce(0) { $0 + $1.files.count }
        let total = items.reduce(0) { $0 + $1.files.count } + stagedFiles
        let pending = items.filter { needsMatch($0) && !matchTried.contains($0.id) }.reduce(0) { $0 + $1.files.count }
        scanFound = max(total, crawlActive ? scanFound : 0)
        scanDone = total - stagedFiles - pending
    }

    /// Match posters for anything not matched yet; keeps waiting for new items while the crawl runs.
    private func matchLoop() async {
        var done = 0
        while true {
            if Task.isCancelled { return }
            let stagedNext = stagedOrder.lazy.compactMap { self.staged[$0] }.first
            guard let next = stagedNext ?? items.first(where: { needsMatch($0) && !matchTried.contains($0.id) }) else {
                if !crawlActive { break }
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let id = next.id
            matchTried.insert(id)
            inMatch = id
            defer { inMatch = nil }
            done += 1
            await AppActivity.shared.waitUntilActive()     // pause (not drop) metadata work while in background
            var item = next
            if !crawlActive { progress = "正在匹配海报：\(item.title)" }
            if item.tmdbId == nil {
                let p = ParsedName(title: item.title, year: item.year, season: nil, episode: nil)
                guard let m = await TMDB.search(title: p.title, year: p.year, tv: item.isTV) else { reveal(id); continue }
                item.title = m.title.isEmpty ? item.title : m.title
                item.originalTitle = m.originalTitle; item.year = m.year ?? item.year; item.overview = m.overview ?? item.overview
                item.poster = m.poster ?? item.poster; item.backdrop = m.backdrop; item.rating = m.rating; item.tmdbId = m.id
                let gs = m.genreIds.compactMap { TMDB.genreName($0) }
                if !gs.isEmpty { item.genres = gs }
                if m.kind == "tv" { item.kind = "tv" }
            }
            if item.isTV, let tid = item.tmdbId {
                let missing = Set(item.files.filter { $0.episodeTitle == nil && $0.episode != nil }.compactMap { $0.season })
                for sn in missing {
                    let eps = await TMDB.season(tvId: tid, season: sn)
                    for i in item.files.indices where item.files[i].season == sn && item.files[i].episodeTitle == nil {
                        if let e = item.files[i].episode, let info = eps[e] { item.files[i].episodeTitle = info.name; item.files[i].still = info.still }
                    }
                }
            }
            if var st = staged[id] {
                // first time it shows up: with its poster already in place
                st.title = item.title; st.originalTitle = item.originalTitle; st.year = item.year; st.overview = item.overview
                st.poster = item.poster; st.backdrop = item.backdrop; st.rating = item.rating; st.tmdbId = item.tmdbId
                st.genres = item.genres; st.kind = item.kind
                for i in st.files.indices {
                    if let f = item.files.first(where: { $0.id == st.files[i].id }), f.episodeTitle != nil {
                        st.files[i].episodeTitle = f.episodeTitle; st.files[i].still = f.still
                    }
                }
                staged[id] = st
                reveal(id)
            } else if let j = items.firstIndex(where: { $0.id == id }) {
                // merge metadata only: the file list may have grown while we waited on TMDB
                var cur = items[j]
                cur.title = item.title; cur.originalTitle = item.originalTitle; cur.year = item.year; cur.overview = item.overview
                cur.poster = item.poster; cur.backdrop = item.backdrop; cur.rating = item.rating; cur.tmdbId = item.tmdbId
                cur.genres = item.genres; cur.kind = item.kind
                for i in cur.files.indices {
                    if let f = item.files.first(where: { $0.id == cur.files[i].id }), f.episodeTitle != nil {
                        cur.files[i].episodeTitle = f.episodeTitle; cur.files[i].still = f.still
                    }
                }
                items[j] = cur
            }
            refreshCounts()
            if done % 10 == 0 { save() }
        }
        save()
    }
}
