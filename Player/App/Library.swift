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

    /// Cloud drives throttle bursts of directory listings; retry with backoff instead of silently dropping the folder.
    private func listRetrying(_ p: SourceProvider, _ dir: RemoteFile?, cloud: Bool) async throws -> [RemoteFile] {
        var delay: UInt64 = 1_200_000_000
        for attempt in 0..<5 {
            if cloud { try? await Task.sleep(nanoseconds: 200_000_000) }
            do { return try await p.list(dir) } catch {
                if attempt == 4 || error is CancellationError { throw error }
                progress = "网盘限流，稍等后重试 \(dir?.name ?? "")…"
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        return []
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
            guard let id = it.tmdbId, let d = await TMDB.details(id: id, tv: it.isTV) else { continue }
            guard let i = items.firstIndex(where: { $0.id == it.id }) else { continue }
            if !d.genres.isEmpty { items[i].genres = d.genres }
            items[i].certification = d.certification ?? ""
            items[i].countries = d.countries
            changed += 1
            if changed % 20 == 0 { save() }
        }
        if changed > 0 { save() }
    }

    // MARK: scanning

    private struct Found { var source: MediaSource; var folder: LibraryFolder; var file: RemoteFile; var parents: [String]; var subs: [RemoteFile] }

    func scan() async {
        if scanning { rescanPending = true; return }
        repeat {
            rescanPending = false
            await scanOnce()
        } while rescanPending
    }

    private func scanOnce() async {
        scanning = true
        defer { scanning = false; progress = "" }
        var errors: [String] = []
        var found: [Found] = []
        var failedFolders = Set<String>()
        for folder in folders {
            guard let src = SourceStore.shared.source(folder.sourceId) else { continue }
            let provider = SourceStore.shared.provider(for: src)
            if !folder.dir.isDir {   // a single video added directly
                var tagged = folder.dir
                tagged.meta["folder"] = folder.id.uuidString
                found.append(Found(source: src, folder: folder, file: tagged, parents: [], subs: []))
                continue
            }
            var queue: [(RemoteFile, [String], Int)] = [(folder.dir, folder.dir.meta["root"] == "1" ? [] : [folder.dir.name], 0)]
            let cloud = ![.smb, .webdav, .local, .emby, .jellyfin].contains(src.kind)
            while !queue.isEmpty, found.count < 50000 {
                let (dir, parents, depth) = queue.removeFirst()
                progress = "正在扫描 \(dir.name)…"
                let list: [RemoteFile]
                do { list = try await listRetrying(provider, dir.meta["root"] == "1" ? nil : dir, cloud: cloud) } catch {
                    errors.append("\(dir.name)：\(error.localizedDescription)")
                    failedFolders.insert(folder.id.uuidString)
                    continue
                }
                for f in list {
                    if f.isDir {
                        if depth < 12, !f.name.hasPrefix("@"), !["sample", "extras", "featurettes"].contains(f.name.lowercased()) {
                            queue.append((f, [f.name] + parents, depth + 1))
                        }
                    } else if f.isVideo {
                        let ln = f.name.lowercased()
                        if ln.contains("sample") || ln.hasPrefix("._") { continue }
                        var tagged = f
                        tagged.meta["folder"] = folder.id.uuidString
                        found.append(Found(source: src, folder: folder, file: tagged, parents: parents,
                                           subs: SubtitleService.sidecars(for: f, in: list)))
                    }
                }
            }
        }

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
            } else {
                p = NameParser.parse(f.file.name, parents: f.parents)
            }
            let key = (p.isEpisode ? "tv:" : "movie:") + p.title.lowercased() + (p.isEpisode ? "" : ":\(p.year ?? 0)")
            let lf = LibraryFile(id: f.source.id.uuidString + ":" + f.file.id, sourceId: f.source.id, file: f.file,
                                 season: p.season, episode: p.episode, subtitles: f.subs)
            if groups[key] == nil { groups[key] = ScanGroup(parsed: p, files: [], serverPoster: f.file.posterURL, serverOverview: f.file.overview); order.append(key) }
            groups[key]?.files.append(lf)
        }

        // match with TMDB
        let old = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newItems: [LibraryItem] = []
        var done = 0
        for key in order {
            guard let g = groups[key] else { continue }
            done += 1
            progress = "正在匹配海报 \(done)/\(order.count)：\(g.parsed.title)"
            let isTV = g.parsed.isEpisode
            var item = LibraryItem(id: key, kind: isTV ? "tv" : "movie", title: g.parsed.title, year: g.parsed.year,
                                   overview: g.serverOverview, poster: g.serverPoster, files: g.files)
            if let prev = old[key], prev.tmdbId != nil {
                item.title = prev.title; item.originalTitle = prev.originalTitle; item.year = prev.year; item.overview = prev.overview
                item.poster = prev.poster; item.backdrop = prev.backdrop; item.rating = prev.rating; item.tmdbId = prev.tmdbId
                item.added = prev.added
                item.genres = prev.genres; item.certification = prev.certification; item.countries = prev.countries
                for i in item.files.indices {
                    if let pf = prev.files.first(where: { $0.id == item.files[i].id }) {
                        item.files[i].episodeTitle = pf.episodeTitle; item.files[i].still = pf.still
                    }
                }
            } else if let m = await TMDB.search(title: g.parsed.title, year: g.parsed.year, tv: isTV) {
                item.title = m.title.isEmpty ? item.title : m.title
                item.originalTitle = m.originalTitle; item.year = m.year ?? item.year; item.overview = m.overview ?? item.overview
                item.poster = m.poster ?? item.poster; item.backdrop = m.backdrop; item.rating = m.rating; item.tmdbId = m.id
                let gs = m.genreIds.compactMap { TMDB.genreName($0) }
                if !gs.isEmpty { item.genres = gs }
                if m.kind == "tv" {
                    item.kind = "tv"
                    for s in Set(item.files.compactMap { $0.season }) {
                        let eps = await TMDB.season(tvId: m.id, season: s)
                        for i in item.files.indices where item.files[i].season == s {
                            if let e = item.files[i].episode, let info = eps[e] {
                                item.files[i].episodeTitle = info.name; item.files[i].still = info.still
                            }
                        }
                    }
                }
            }
            newItems.append(item)
        }
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
        items = newItems
        lastScan = Date()
        UserDefaults.standard.set(lastScan, forKey: "lib.lastScan")
        save()
        Task { await enrich() }
        precachePosters(newItems)
        if newItems.isEmpty {
            lastResult = errors.first.map { "扫描失败：\($0)" } ?? (folders.isEmpty ? nil : "没在这些文件夹里找到视频文件")
        } else {
            lastResult = "扫描完成：\(newItems.count) 部影片" + (errors.isEmpty ? "" : "（\(errors.count) 个文件夹读取失败）")
        }
    }
}
