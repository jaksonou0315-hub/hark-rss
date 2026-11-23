import Foundation
import UIKit
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
    var keywords: [String]? = nil     // TMDB keywords (lowercased English), used for the BL shelf
    var collectionId: Int? = nil      // TMDB belongs_to_collection (movies), groups a series in the 电影 grid
    var collectionName: String? = nil
    var collectionPoster: URL? = nil
    var regions: [String]? = nil      // ISO country codes, origin first (region sub-tabs)
    var lang: String? = nil           // TMDB original_language
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
    let live = ScanLive()
    var progress: String {
        get { live.progress }
        set { if live.progress != newValue { live.progress = newValue } }
    }
    @Published var lastResult: String?
    @Published var lastScan: Date? = UserDefaults.standard.object(forKey: "lib.lastScan") as? Date
    private var rescanPending = false
    private var pendingForce = false
    var scanFound = 0 { didSet { pushLine() } }          // video files found so far
    var scanDone = 0 { didSet { pushLine() } }           // files in library with poster matched (or tried)
    var foldersLeft = 0 { didSet { if foldersLeft != oldValue { pushLine() } } }
    var foldersRead = 0 { didSet { if foldersRead / 5 != oldValue / 5 { pushLine() } } }
    var matching = false
    var countLine: String? {
        guard scanning else { return nil }
        let main = "已找到 \(scanFound) 个文件，已完成 \(min(scanDone, scanFound)) 个，剩余 \(max(0, scanFound - scanDone)) 个"
        return main
    }
    private func pushLine() {
        let l = countLine
        if live.line != l { live.line = l }
    }
    private static let ioQueue = DispatchQueue(label: "library.save", qos: .utility)
    @Published private(set) var enriching = false
    @Published private(set) var enrichLeft = 0

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
    /// Encode + write off the main thread (library.json can be several MB).
    private func save() {
        let snap = Snapshot(folders: folders, items: items)
        let url = fileURL
        Self.ioQueue.async {
            if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
        }
    }

    var movies: [LibraryItem] { items.filter { !$0.isTV }.sorted { $0.added > $1.added } }
    var shows: [LibraryItem] { items.filter { $0.isTV }.sorted { $0.added > $1.added } }

    func addFolder(source: MediaSource, dir: RemoteFile) {
        guard !folders.contains(where: { f in
            f.sourceId == source.id && (f.dir.id == dir.id || f.dir.meta["root"] == "1"
                || (!f.dir.path.isEmpty && dir.path.hasPrefix(f.dir.path.hasSuffix("/") ? f.dir.path : f.dir.path + "/")))
        }) else { return }      // already in the library, or inside a library folder
        folders.append(LibraryFolder(sourceId: source.id, dir: dir, title: "\(source.name) · \(dir.name)"))
        save()
        Task { await scan(force: false) }   // delta pass: only the new folder has never been listed
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
        defer { enriching = false; enrichLeft = 0 }
        let srcs = SourceStore.shared.sources
        let prefetchOff = Set(srcs.filter { $0.extra["prefetch"] == "0" }.map(\.id))
        let todo = items.filter { it in
            it.tmdbId != nil && (it.certification == nil || it.genres == nil || it.keywords == nil || !(it.keywords ?? []).contains("#v4"))
                && !(it.files.allSatisfy { prefetchOff.contains($0.sourceId) })
        }
        var changed = 0
        var pending: [String: TMDBDetails] = [:]
        var lastFlush = Date()
        // Apply fetched details in batches: one publish per batch instead of six per film
        // (each publish re-rendered Home and froze scrolling while 数据同步中).
        func flush() {
            guard !pending.isEmpty else { return }
            var xs = items
            for i in xs.indices {
                guard let d = pending[xs[i].id] else { continue }
                if !d.genres.isEmpty { xs[i].genres = d.genres }
                xs[i].certification = d.certification ?? ""
                xs[i].countries = d.countries
                xs[i].keywords = d.keywords
                xs[i].collectionId = d.collectionId; xs[i].collectionName = d.collectionName; xs[i].collectionPoster = d.collectionPoster
                xs[i].regions = d.regionCodes; xs[i].lang = d.lang
            }
            pending = [:]; lastFlush = Date()
            items = xs
        }
        enrichLeft = todo.count
        // 8 requests in flight at a time (TMDB allows ~40/s); one at a time took over an hour for a big library,
        // and anything not yet enriched sits in the region tabs' 其他.
        var idx = 0
        while idx < todo.count {
            await AppActivity.shared.waitUntilActive()
            let chunk = Array(todo[idx..<min(idx + 8, todo.count)])
            idx += chunk.count
            let got = await withTaskGroup(of: (String, TMDBDetails?).self) { g -> [(String, TMDBDetails?)] in
                for it in chunk {
                    let id = it.tmdbId ?? 0, tv = it.isTV, key = it.id
                    g.addTask { (key, await TMDB.details(id: id, tv: tv)) }
                }
                var out: [(String, TMDBDetails?)] = []
                for await r in g { out.append(r) }
                return out
            }
            for (k, d) in got { if let d { pending[k] = d; changed += 1 } }
            enrichLeft = todo.count - idx
            if pending.count >= 80 || Date().timeIntervalSince(lastFlush) > 4 { flush(); save() }
        }
        flush()
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

    private var crawlActive = false { didSet { pushLine() } }
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
        scanFound = 0; scanDone = 0; foldersLeft = 0; foldersRead = 0; matching = true
        crawlActive = true
        matchTried = []
        staged = [:]; stagedOrder = []
        knownIds = Set(items.map(\.id))
        // keep reading folders for the ~30 s iOS allows after leaving the app
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "library-scan") { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        defer {
            scanning = false; matching = false; crawlActive = false; progress = ""; pushLine()
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        let before = Set(items.flatMap { $0.files.map(\.id) })
        let folderSnapshot = folders

        // show videos as soon as their folder is read, and match posters while the crawl goes on
        let publisher = Task { @MainActor [weak self] in
            var lastSig = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                let sig = self.scanFound &* 31 &+ self.foldersLeft
                if sig == lastSig { continue }                      // nothing new was read
                lastSig = sig
                let f = await ScanCenter.shared.snapshotFound(folderSnapshot)
                let current = self.items + Array(self.staged.values)
                // grouping + name parsing for thousands of files: off the main thread
                let (built, _) = await Task.detached(priority: .utility) { Self.buildItems(f, current: current) }.value
                guard !Task.isCancelled else { return }
                self.publish(built, keepMissing: true)
            }
        }
        let matcher = Task { @MainActor [weak self] in await self?.matchLoop() }

        let outcome = await ScanCenter.shared.collect(folders, force: force, counts: { [weak self] found, left, read in
            self?.foldersLeft = left
            self?.foldersRead = read
            if let self, found > self.scanFound { self.scanFound = found }
        }) { [weak self] msg in self?.progress = msg }
        publisher.cancel()
        let errors = outcome.errors
        let failedFolders = outcome.failedFolders

        let current = items + Array(staged.values)
        let foundAll = outcome.found
        var (newItems, _) = await Task.detached(priority: .userInitiated) { Self.buildItems(foundAll, current: current) }.value
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
    nonisolated private static func buildItems(_ found: [ScanFound], current: [LibraryItem]) -> ([LibraryItem], Int) {
        // group
        struct ScanGroup { var parsed: ParsedName; var files: [LibraryFile]; var serverPoster: URL?; var serverOverview: String? }
        var groups: [String: ScanGroup] = [:]
        var order: [String] = []
        let excluded = LibraryStore.excludedFiles()
        for f in found {
            if excluded.contains(f.source.id.uuidString + ":" + f.file.id) { continue }
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
            var ff = f.file
            let rootName = f.folder.dir.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ff.meta["dirPath"] = "/" + ([rootName.isEmpty ? f.folder.title : rootName] + f.parents.reversed()).filter { !$0.isEmpty }.joined(separator: "/")
            let lf = LibraryFile(id: f.source.id.uuidString + ":" + f.file.id, sourceId: f.source.id, file: ff,
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
                    item.genres = prev.genres; item.certification = prev.certification; item.countries = prev.countries; item.keywords = prev.keywords
                    item.collectionId = prev.collectionId; item.collectionName = prev.collectionName; item.collectionPoster = prev.collectionPoster
                    item.regions = prev.regions; item.lang = prev.lang
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

    // MARK: manual edits (编辑信息 / 移除 / 单片重新扫描)

    struct Override: Codable { var match: TMDBMatch? }       // nil match = 使用原文件数据
    private(set) var overrides: [String: Override] = {
        guard let d = UserDefaults.standard.data(forKey: "lib.overrides"),
              let v = try? JSONDecoder().decode([String: Override].self, from: d) else { return [:] }
        return v
    }() {
        didSet { if let d = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(d, forKey: "lib.overrides") } }
    }

    nonisolated static func excludedFiles() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "lib.excluded") ?? [])
    }

    /// 编辑信息: pin a TMDB match (or the file's own data) for this item; survives rescans.
    func applyMatch(_ itemId: String, _ m: TMDBMatch?) async {
        overrides[itemId] = Override(match: m)
        guard let j = items.firstIndex(where: { $0.id == itemId }) else { return }
        var it = items[j]
        if let m {
            it.title = m.title.isEmpty ? it.title : m.title
            it.originalTitle = m.originalTitle; it.year = m.year ?? it.year; it.overview = m.overview
            it.poster = m.poster; it.backdrop = m.backdrop; it.rating = m.rating; it.tmdbId = m.id
            it.kind = m.kind
            let gs = m.genreIds.compactMap { TMDB.genreName($0) }
            it.genres = gs.isEmpty ? nil : gs
            it.certification = nil; it.countries = nil; it.keywords = nil
            it.collectionId = nil; it.collectionName = nil; it.collectionPoster = nil; it.regions = nil; it.lang = nil
            for i in it.files.indices { it.files[i].episodeTitle = nil; it.files[i].still = nil }
        } else {
            let first = it.files.first
            let p = first.map { NameParser.parse($0.file.name, parents: []) }
            it.title = p?.title ?? it.title; it.year = p?.year; it.originalTitle = nil
            it.overview = first?.file.overview; it.poster = first?.file.posterURL; it.backdrop = nil
            it.rating = nil; it.tmdbId = nil; it.genres = nil; it.certification = nil; it.countries = nil; it.keywords = nil
            it.collectionId = nil; it.collectionName = nil; it.collectionPoster = nil; it.regions = nil; it.lang = nil
        }
        items[j] = it
        save()
        if m != nil { await fillEpisodes(itemId) }
        Task { await enrich() }
    }

    private func fillEpisodes(_ itemId: String) async {
        guard let j = items.firstIndex(where: { $0.id == itemId }), items[j].isTV, let tid = items[j].tmdbId else { return }
        var it = items[j]
        for sn in Set(it.files.compactMap { $0.season }) {
            let eps = await TMDB.season(tvId: tid, season: sn)
            for i in it.files.indices where it.files[i].season == sn {
                if let e = it.files[i].episode, let info = eps[e] { it.files[i].episodeTitle = info.name; it.files[i].still = info.still }
            }
        }
        if let k = items.firstIndex(where: { $0.id == itemId }) { items[k].files = it.files.map { f in
            var f = f
            if let n = it.files.first(where: { $0.id == f.id }) { f.episodeTitle = n.episodeTitle; f.still = n.still }
            return f
        } }
        save()
    }

    /// 从媒体库中移除: hide these files from now on (they stay on the drive).
    func removeItem(_ itemId: String) {
        guard let it = items.first(where: { $0.id == itemId }) else { return }
        var ex = Self.excludedFiles()
        for f in it.files { ex.insert(f.id) }
        UserDefaults.standard.set(Array(ex), forKey: "lib.excluded")
        items.removeAll { $0.id == itemId }
        save()
    }

    func restoreRemoved() {
        UserDefaults.standard.removeObject(forKey: "lib.excluded")
    }
    var removedCount: Int { Self.excludedFiles().count }

    /// 单片「重新扫描文件」: relist the folders this item's files live in, rebuild, rematch it.
    func rescanItem(_ itemId: String) async {
        guard let it = items.first(where: { $0.id == itemId }) else { return }
        progress = "正在重新扫描 \(it.title)…"
        defer { progress = "" }
        let fileIds = Set(it.files.map(\.file.id))
        for sid in Set(it.files.map(\.sourceId)) {
            guard let src = SourceStore.shared.source(sid), !src.kind.isMediaServer else { continue }
            let db = ScanCenter.shared.db(sid)
            let parents = db.dirs.values.filter { $0.children.contains { fileIds.contains($0.id) } }
            for snap in parents { _ = try? await ScanCenter.shared.browse(src, snap.dir) }
        }
        let f = await ScanCenter.shared.snapshotFound(folders)
        let current = items
        let (built, _) = await Task.detached(priority: .userInitiated) { Self.buildItems(f, current: current) }.value
        let have = Set(built.map(\.id))
        items = built + items.filter { !have.contains($0.id) }
        // force a fresh match unless the user pinned one
        if let j = items.firstIndex(where: { $0.id == itemId }) {
            if let o = overrides[itemId] { await applyMatch(itemId, o.match); return }
            var x = items[j]
            x.tmdbId = nil
            for i in x.files.indices { x.files[i].episodeTitle = nil }
            items[j] = x
            if let tid = x.files.lazy.compactMap({ TMDB.idInPath($0.file.path + "/" + $0.file.name) }).first,
               let m = await TMDB.byId(tid, tv: x.isTV) {
                await applyMatch(itemId, m); overrides[itemId] = nil; return
            }
            if let m = await TMDB.search(title: x.title, year: x.year, tv: x.isTV) {
                await applyMatch(itemId, m); overrides[itemId] = nil
            }
        }
        save()
    }

    private func needsMatch(_ it: LibraryItem) -> Bool {
        if it.tmdbId == nil, let o = overrides[it.id], o.match == nil { return false }
        return it.tmdbId == nil || (it.isTV && it.files.contains { $0.episodeTitle == nil && $0.episode != nil })
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
                let manual = overrides[id]
                if let manual, manual.match == nil { reveal(id); continue }          // 使用原文件数据
                var found: TMDBMatch? = manual?.match
                if found == nil, let tid = item.files.lazy.compactMap({ TMDB.idInPath($0.file.path + "/" + $0.file.name) }).first {
                    found = await TMDB.byId(tid, tv: item.isTV)
                    if found == nil { found = await TMDB.byId(tid, tv: !item.isTV) }
                }
                if found == nil { found = await TMDB.search(title: p.title, year: p.year, tv: item.isTV) }
                guard let m = found else { reveal(id); continue }
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
