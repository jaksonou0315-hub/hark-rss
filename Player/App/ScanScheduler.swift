import Foundation
import SwiftUI
import UIKit

// MARK: - Errors

/// Non-2xx HTTP response. Message text matches the old AppError wording.
struct HTTPStatusError: LocalizedError {
    let code: Int
    let retryAfter: Int?      // seconds
    let message: String
    var errorDescription: String? { message }

    /// Retry-After is seconds or an HTTP date — never milliseconds.
    static func retryAfter(_ h: HTTPURLResponse) -> Int? {
        guard let v = h.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let s = Int(v) { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = f.date(from: v) { return max(0, Int(d.timeIntervalSinceNow.rounded(.up))) }
        return nil
    }
}

enum ScanError: Error {
    case tooManyRequests(retryAfterSeconds: Int?)
    case forbidden, unauthorized, timeout, network, other

    static func classify(_ e: Error) -> ScanError {
        if let h = e as? HTTPStatusError {
            switch h.code {
            case 429, 503: return .tooManyRequests(retryAfterSeconds: h.retryAfter)
            case 401: return .unauthorized
            case 403: return .forbidden
            case 408, 504: return .timeout
            case 500...599: return .network
            default: return .other
            }
        }
        if let u = e as? URLError {
            switch u.code {
            case .timedOut: return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .secureConnectionFailed, .resourceUnavailable, .dataNotAllowed, .internationalRoamingOff:
                return .network
            default: return .other
            }
        }
        let m = e.localizedDescription.lowercased()
        if m.contains("429") || m.contains("频繁") || m.contains("限流") || m.contains("too many") || m.contains("rate limit") || m.contains("稍后") {
            return .tooManyRequests(retryAfterSeconds: nil)
        }
        if m.contains("401") || m.contains("过期") || m.contains("失效") || m.contains("重新登录") || m.contains("unauthorized") { return .unauthorized }
        if m.contains("403") || m.contains("forbidden") || m.contains("无权") { return .forbidden }
        if m.contains("超时") || m.contains("timed out") { return .timeout }
        return .other
    }
}

// MARK: - Per-source gate (pacing + AIMD + backoff + suspension)

struct GateStats: Hashable {
    var requests = 0
    var throttled = 0
    var errors = 0
    var avgMs = 0
    var delayMs = 0
    var suspendedUntil: Date?
}

actor SourceGate {
    let maxRetries = 5
    private let minDelayMs: Int
    private let maxDelayMs = 15_000
    private var currentDelayMs: Int
    private var nextSlot = Date.distantPast
    private(set) var suspendedUntil = Date.distantPast
    private var requests = 0, throttled = 0, errors = 0
    private var totalMs = 0.0

    init(minDelayMs: Int) {
        self.minDelayMs = minDelayMs
        currentDelayMs = minDelayMs
    }

    /// Reserve the next request slot for this source, then wait for it.
    func waitTurn() async throws {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(Double(currentDelayMs) / 1000)
        let wait = slot.timeIntervalSince(now)
        if wait > 0.001 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
    }

    /// AIMD: speed back up slowly on success…
    func onSuccess(ms: Double) {
        requests += 1; totalMs += ms
        currentDelayMs = max(minDelayMs, Int(Double(currentDelayMs) * 0.9))
    }
    /// …and slow down hard when the server pushes back.
    func onThrottled() {
        requests += 1; throttled += 1
        currentDelayMs = min(maxDelayMs, max(currentDelayMs * 2, max(minDelayMs, 250)))
    }
    func onError() { requests += 1; errors += 1 }

    /// Exponential backoff with jitter (raw/2 … raw).
    func backoffMs(retry: Int) -> Int {
        let base = Double(max(minDelayMs, 1000))
        let raw = min(maxDelayMs, Int(base * pow(1.6, Double(retry))))
        return Int.random(in: max(1, raw / 2)...max(1, raw))
    }

    func suspend(for seconds: TimeInterval) { suspendedUntil = Date().addingTimeInterval(seconds) }
    var isSuspended: Bool { Date() < suspendedUntil }

    func stats() -> GateStats {
        GateStats(requests: requests, throttled: throttled, errors: errors,
                  avgMs: requests > 0 ? Int(totalMs / Double(max(1, requests - throttled - errors))) : 0,
                  delayMs: currentDelayMs, suspendedUntil: isSuspended ? suspendedUntil : nil)
    }
}

// MARK: - App activity (pause metadata work in background instead of dropping it)

@MainActor
final class AppActivity {
    static let shared = AppActivity()
    private(set) var active = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppActivity.shared.active = false }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppActivity.shared.resume() }
        }
    }
    private func resume() {
        active = true
        let w = waiters; waiters = []
        w.forEach { $0.resume() }
    }
    func waitUntilActive() async {
        if active { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - Directory snapshots

struct DirSnap: Codable {
    var dir: RemoteFile?          // nil = drive root
    var children: [RemoteFile]    // dirs, videos, subtitles only
    var sig: String
    var verifiedAt: Date
    var changedAt: Date
    var forbidden = false
}

@MainActor
final class SnapshotDB {
    let sourceId: UUID
    private(set) var dirs: [String: DirSnap] = [:]
    private var dirty = false

    private static let folder: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("scan", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var url: URL { Self.folder.appendingPathComponent("\(sourceId.uuidString).json") }

    init(sourceId: UUID) {
        self.sourceId = sourceId
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([String: DirSnap].self, from: d) { dirs = v }
    }

    static func key(_ dir: RemoteFile?) -> String { dir?.id ?? "__root__" }
    subscript(_ key: String) -> DirSnap? { dirs[key] }

    /// Adaptive TTL: recently changed dirs are rechecked within hours, dormant ones about weekly.
    func isDue(_ key: String, now: Date = Date()) -> Bool {
        guard let s = dirs[key] else { return true }
        let sinceChange = now.timeIntervalSince(s.changedAt)
        var ttl = min(7 * 86_400, max(3_600, sinceChange / 4))
        if !s.children.contains(where: { $0.isDir }) { ttl = min(7 * 86_400, ttl * 2) }   // leaf folders change rarely
        return now.timeIntervalSince(s.verifiedAt) > ttl
    }

    /// Store a fresh listing; dirs that vanished are deleted together with all their descendants.
    @discardableResult
    func store(_ dir: RemoteFile?, listing: [RemoteFile], now: Date = Date()) -> Bool {
        let key = Self.key(dir)
        let kept = listing.filter { $0.isDir || $0.isVideo || $0.isSubtitle }
        let sig = Self.signature(kept)
        let old = dirs[key]
        if let old {
            let newIds = Set(kept.filter(\.isDir).map(\.id))
            for gone in old.children where gone.isDir && !newIds.contains(gone.id) { cascadeDelete(gone.id) }
        }
        let changed = old?.sig != sig
        dirs[key] = DirSnap(dir: dir, children: kept, sig: sig, verifiedAt: now, changedAt: changed ? now : (old?.changedAt ?? now))
        dirty = true
        return changed
    }

    func markForbidden(_ dir: RemoteFile?) {
        let key = Self.key(dir)
        var s = dirs[key] ?? DirSnap(dir: dir, children: [], sig: "", verifiedAt: Date(), changedAt: Date())
        s.forbidden = true
        s.verifiedAt = Date()
        dirs[key] = s
        dirty = true
    }

    func cascadeDelete(_ key: String) {
        var stack = [key]
        var seen = Set<String>()
        while let k = stack.popLast() {
            guard seen.insert(k).inserted, let s = dirs.removeValue(forKey: k) else { continue }
            stack += s.children.filter(\.isDir).map(\.id)
        }
        dirty = true
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        if let d = try? JSONEncoder().encode(dirs) { try? d.write(to: url, options: .atomic) }
    }

    func purge() {
        dirs = [:]; dirty = false
        try? FileManager.default.removeItem(at: url)
    }

    /// Stable across launches (FNV-1a 64) — Hasher is seeded per process.
    private static func signature(_ files: [RemoteFile]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for f in files.sorted(by: { $0.id < $1.id }) {
            for b in "\(f.id)|\(f.name)|\(f.size)|\(f.isDir ? 1 : 0)\n".utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        }
        return String(h, radix: 16)
    }
}

// MARK: - Scan rules

enum ScanRules {
    static let maxDepth = 8
    private static let skipNames: Set<String> = [
        "sample", "samples", "extras", "featurettes", "缩略图", "thumbnails", "thumbs", "lost+found",
        "system volume information", "aacs", "certificate", "recycle", "recycler", "回收站", "trash",
    ]
    static func skipDir(_ name: String) -> Bool {
        let l = name.lowercased()
        if l.hasPrefix(".") || l.hasPrefix("@") || l.hasPrefix("#") || l.hasPrefix("$") { return true }   // @eaDir #recycle $RECYCLE.BIN .Trash-1000
        return skipNames.contains(l)
    }
    static func skipFile(_ f: RemoteFile) -> Bool {
        let l = f.name.lowercased()
        return l.hasPrefix("._") || l.hasPrefix(".") || l.contains("sample")
    }
    static func isDiscDir(_ name: String) -> Bool { ["bdmv", "video_ts"].contains(name.lowercased()) }
}

// MARK: - Jobs

enum ScanTaskType: Int { case backgroundDelta = 1, userTriggered = 10 }

private struct ScanJob {
    var key: String
    var dir: RemoteFile?
    var depth: Int
    var type: ScanTaskType
    var retry = 0
    var notBefore = Date.distantPast
    var reauthed = false
    var discLevel = 0          // 1 = inside BDMV (only STREAM followed), 2 = STREAM / VIDEO_TS
    var seq = 0
}

struct ScanFound {
    var source: MediaSource
    var folder: LibraryFolder
    var file: RemoteFile
    var parents: [String]
    var subs: [RemoteFile]
    var titleOverride: String? = nil
}

struct ScanOutcome {
    var found: [ScanFound] = []
    var errors: [String] = []
    var failedFolders = Set<String>()
    var listed = 0
    var skipped = 0
}

// MARK: - Scan center

@MainActor
final class ScanCenter: ObservableObject {
    static let shared = ScanCenter()
    @Published private(set) var stats: [UUID: GateStats] = [:]
    private var gates: [UUID: SourceGate] = [:]
    private var dbs: [UUID: SnapshotDB] = [:]
    private var cancelled = Set<UUID>()

    func gate(_ s: MediaSource) -> SourceGate {
        if let g = gates[s.id] { return g }
        let ms: Int
        switch s.kind {
        case .local, .smb, .emby, .jellyfin: ms = 0
        case .webdav: ms = 150
        default: ms = 300        // cloud drives: be gentle by default
        }
        let g = SourceGate(minDelayMs: ms)
        gates[s.id] = g
        return g
    }
    func db(_ id: UUID) -> SnapshotDB {
        if let d = dbs[id] { return d }
        let d = SnapshotDB(sourceId: id)
        dbs[id] = d
        return d
    }
    private func workers(_ s: MediaSource) -> Int {
        switch s.kind {
        case .local, .smb: return 3
        default: return 2
        }
    }

    /// Source deleted: stop its queued jobs and drop its snapshots.
    func cancel(_ id: UUID) {
        cancelled.insert(id)
        db(id).purge()
        dbs[id] = nil
        gates[id] = nil
        stats[id] = nil
    }

    func refreshStats() async {
        for (id, g) in gates { stats[id] = await g.stats() }
    }

    /// One user-facing listing (FolderView): paced through the same gate, refreshes this dir's snapshot.
    func browse(_ s: MediaSource, _ dir: RemoteFile?) async throws -> [RemoteFile] {
        let g = gate(s)
        let provider = SourceStore.shared.provider(for: s)
        var attempt = 0
        while true {
            try await g.waitTurn()
            let t0 = Date()
            do {
                let list = try await provider.list(dir)
                await g.onSuccess(ms: Date().timeIntervalSince(t0) * 1000)
                if !s.kind.isMediaServer { db(s.id).store(dir, listing: list); db(s.id).flush() }
                return list
            } catch {
                if error is CancellationError { throw error }
                let kind = ScanError.classify(error)
                switch kind {
                case .tooManyRequests(let secs) where attempt < 2:
                    await g.onThrottled()
                    var ms = await g.backoffMs(retry: attempt)
                    if let secs { ms = min(secs, 20) * 1000 }
                    try await Task.sleep(for: .milliseconds(ms))
                case .timeout where attempt < 2, .network where attempt < 2:
                    await g.onError()
                    try await Task.sleep(for: .milliseconds(await g.backoffMs(retry: attempt)))
                default:
                    await g.onError()
                    throw error
                }
                attempt += 1
            }
        }
    }

    // MARK: crawl

    /// Crawl every library folder and return the videos found.
    /// force = list every dir now; otherwise only dirs whose snapshot is missing or past its adaptive TTL.
    func collect(_ folders: [LibraryFolder], force: Bool, counts: @escaping (Int, Int) -> Void = { _, _ in },
                 progress: @escaping (String) -> Void) async -> ScanOutcome {
        var out = ScanOutcome()
        let bySource = Dictionary(grouping: folders, by: \.sourceId)
        for (sid, fs) in bySource {
            guard let src = SourceStore.shared.source(sid) else { continue }
            cancelled.remove(sid)
            if src.kind.isMediaServer {
                await collectServer(src, fs, into: &out, progress: progress)
                continue
            }
            let run = CrawlRun(center: self, source: src, db: db(sid), gate: gate(src), force: force, progress: progress)
            let base = out.found.count
            run.counts = { found, left in counts(base + found, left) }
            for f in fs where f.dir.isDir {
                run.enqueue(dir: f.dir.meta["root"] == "1" ? nil : f.dir, depth: 0, type: .userTriggered)
            }
            await run.run()
            out.errors += run.errors
            out.listed += run.listed
            out.skipped += run.skipped
            db(sid).flush()
            for f in fs {
                if !f.dir.isDir {
                    var t = f.dir; t.meta["folder"] = f.id.uuidString
                    out.found.append(ScanFound(source: src, folder: f, file: t, parents: [], subs: []))
                    continue
                }
                let rootKey = f.dir.meta["root"] == "1" ? "__root__" : f.dir.id
                if db(sid)[rootKey] == nil { out.failedFolders.insert(f.id.uuidString) }
                assemble(src, f, rootKey: rootKey, rootParents: f.dir.meta["root"] == "1" ? [] : [f.dir.name], into: &out.found)
            }
        }
        await refreshStats()
        return out
    }

    func isCancelled(_ id: UUID) -> Bool { cancelled.contains(id) || SourceStore.shared.source(id) == nil }

    /// Walk the snapshot tree (no network) and turn it into found videos.
    private func assemble(_ src: MediaSource, _ folder: LibraryFolder, rootKey: String, rootParents: [String], into found: inout [ScanFound]) {
        let db = db(src.id)
        var stack: [(String, [String], Int)] = [(rootKey, rootParents, 0)]
        var seen = Set<String>()
        while let top = stack.popLast() {
            let (key, parents, depth) = top
            guard seen.insert(key).inserted, let snap = db[key], !snap.forbidden || !snap.children.isEmpty else { continue }
            let kids = snap.children
            // Blu-ray / DVD folder = one movie: largest stream file, titled by this folder.
            if let disc = kids.first(where: { $0.isDir && ScanRules.isDiscDir($0.name) }),
               let best = discMain(db, disc) {
                var t = best; t.meta["folder"] = folder.id.uuidString; t.meta["disc"] = "1"
                found.append(ScanFound(source: src, folder: folder, file: t, parents: parents, subs: [],
                                       titleOverride: parents.first ?? snap.dir?.name ?? src.name))
            }
            for f in kids {
                if f.isDir {
                    if depth < ScanRules.maxDepth, !ScanRules.skipDir(f.name), !ScanRules.isDiscDir(f.name) {
                        stack.append((f.id, [f.name] + parents, depth + 1))
                    }
                } else if f.isVideo, !ScanRules.skipFile(f) {
                    var t = f; t.meta["folder"] = folder.id.uuidString
                    found.append(ScanFound(source: src, folder: folder, file: t, parents: parents,
                                           subs: SubtitleService.sidecars(for: f, in: kids)))
                }
            }
        }
    }

    private func discMain(_ db: SnapshotDB, _ disc: RemoteFile) -> RemoteFile? {
        guard let s = db[disc.id] else { return nil }
        var pool = s.children.filter { !$0.isDir && $0.isVideo }
        if let stream = s.children.first(where: { $0.isDir && $0.name.lowercased() == "stream" }), let ss = db[stream.id] {
            pool += ss.children.filter { !$0.isDir && $0.isVideo }
        }
        return pool.max { $0.size < $1.size }
    }

    /// Emby / Jellyfin: read the server's own library (flat), never crawl folders.
    private func collectServer(_ src: MediaSource, _ fs: [LibraryFolder], into out: inout ScanOutcome, progress: (String) -> Void) async {
        guard let p = SourceStore.shared.provider(for: src) as? EmbyProvider else { return }
        for f in fs {
            if !f.dir.isDir {
                var t = f.dir; t.meta["folder"] = f.id.uuidString
                out.found.append(ScanFound(source: src, folder: f, file: t, parents: [], subs: []))
                continue
            }
            progress("正在读取 \(src.name) 媒体库…")
            do {
                let items = try await p.allMedia(under: f.dir.meta["root"] == "1" ? nil : f.dir)
                for var it in items {
                    it.meta["folder"] = f.id.uuidString
                    out.found.append(ScanFound(source: src, folder: f, file: it, parents: [], subs: []))
                }
            } catch {
                out.errors.append("\(f.dir.name)：\(error.localizedDescription)")
                out.failedFolders.insert(f.id.uuidString)
            }
        }
    }
}

/// Lets other files start a one-folder crawl without exposing CrawlRun.
enum CrawlRunHandle {
    @MainActor static func make(center: ScanCenter, source: MediaSource, db: SnapshotDB, gate: SourceGate,
                                progress: @escaping (String) -> Void) -> (RemoteFile?) async -> Void {
        { dir in
            let run = CrawlRun(center: center, source: source, db: db, gate: gate, force: false, progress: progress)
            run.enqueue(dir: dir, depth: 0, type: .userTriggered)
            await run.run()
        }
    }
}

/// One source's crawl: deduped priority queue with notBefore delays; workers never sleep while holding a slot.
@MainActor
private final class CrawlRun {
    let center: ScanCenter
    let source: MediaSource
    let db: SnapshotDB
    let gate: SourceGate
    let force: Bool
    let progress: (String) -> Void
    private var pending: [String: ScanJob] = [:]
    private var inFlight = Set<String>()
    private var visited = Set<String>()
    private var seq = 0
    var errors: [String] = []
    var listed = 0
    var skipped = 0
    var videos = 0
    var counts: (Int, Int) -> Void = { _, _ in }

    init(center: ScanCenter, source: MediaSource, db: SnapshotDB, gate: SourceGate, force: Bool, progress: @escaping (String) -> Void) {
        self.center = center; self.source = source; self.db = db; self.gate = gate; self.force = force; self.progress = progress
    }

    func enqueue(dir: RemoteFile?, depth: Int, type: ScanTaskType, retry: Int = 0, delayMs: Int = 0, reauthed: Bool = false, discLevel: Int = 0) {
        let key = SnapshotDB.key(dir)
        if retry == 0 && visited.contains(key) { return }
        if inFlight.contains(key) && retry == 0 { return }
        let notBefore = delayMs > 0 ? Date().addingTimeInterval(Double(delayMs) / 1000) : Date.distantPast
        if var existing = pending[key] {
            if type.rawValue > existing.type.rawValue { existing.type = type }   // keep the higher priority
            existing.notBefore = min(existing.notBefore, notBefore)
            pending[key] = existing
            return
        }
        seq += 1
        pending[key] = ScanJob(key: key, dir: dir, depth: depth, type: type, retry: retry, notBefore: notBefore,
                               reauthed: reauthed, discLevel: discLevel, seq: seq)
    }

    private func nextReady() -> ScanJob? {
        let now = Date()
        guard let job = pending.values.filter({ $0.notBefore <= now })
            .max(by: { ($0.type.rawValue, -$0.seq) < ($1.type.rawValue, -$1.seq) }) else { return nil }
        pending[job.key] = nil
        return job
    }

    func run() async {
        let n = source.kind == .local || source.kind == .smb ? 3 : 2
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<n { g.addTask { await self.worker() } }
        }
    }

    private func worker() async {
        while !Task.isCancelled {
            if center.isCancelled(source.id) { pending.removeAll(); return }
            if let job = nextReady() {
                inFlight.insert(job.key)
                await process(job)
                inFlight.remove(job.key)
                continue
            }
            if pending.isEmpty && inFlight.isEmpty { return }
            // nothing ready: wait for the earliest delayed job (or for an in-flight one to add work)
            let earliest = pending.values.map(\.notBefore).min() ?? Date().addingTimeInterval(0.2)
            let wait = min(max(earliest.timeIntervalSinceNow, 0.05), 0.5)
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
        }
    }

    private func process(_ job: ScanJob) async {
        let key = job.key
        if await gate.isSuspended {
            errors.append("\(source.name)：已暂停扫描（认证失败），30 分钟后再试")
            pending.removeAll()
            return
        }
        // force = relist anything not verified in the last 15 min, so an interrupted full rescan resumes where it stopped
        let recent = db[key].map { Date().timeIntervalSince($0.verifiedAt) < 900 } ?? false
        let mustList = job.retry > 0 || (force ? !recent : db.isDue(key))
        if !mustList, let snap = db[key] {
            visited.insert(key)
            skipped += 1
            expand(job, snap.children)
            return
        }
        progress("正在扫描（已读 \(listed) 个文件夹，剩 \(pending.count + inFlight.count)）\(job.dir?.name ?? source.name)")
        let provider = SourceStore.shared.provider(for: source)
        do {
            try await gate.waitTurn()
            let t0 = Date()
            let list = try await provider.list(job.dir)
            await gate.onSuccess(ms: Date().timeIntervalSince(t0) * 1000)
            listed += 1
            visited.insert(key)
            db.store(job.dir, listing: list)
            if listed % 25 == 0 { db.flush() }      // survive the app being suspended / killed mid-scan
            expand(job, db[key]?.children ?? [])
        } catch {
            if error is CancellationError { return }
            let name = job.dir?.name ?? source.name
            func giveUp(_ msg: String) {
                errors.append(msg)
                visited.insert(key)
                if let snap = db[key] { expand(job, snap.children) }   // keep last known contents
            }
            func retry(_ ms: Int, reauthed: Bool = false) {
                if job.retry < gate.maxRetries {
                    enqueue(dir: job.dir, depth: job.depth, type: job.type, retry: job.retry + 1, delayMs: ms,
                            reauthed: reauthed || job.reauthed, discLevel: job.discLevel)
                } else {
                    giveUp("\(name)：多次重试失败（\(error.localizedDescription)）")
                }
            }
            switch ScanError.classify(error) {
            case .tooManyRequests(let secs):
                await gate.onThrottled()
                progress("网盘限流，稍后重试 \(name)…")
                let ms: Int
                if let secs { ms = secs * 1000 } else { ms = await gate.backoffMs(retry: job.retry) }
                retry(ms)
            case .timeout, .network:
                await gate.onError()
                retry(await gate.backoffMs(retry: job.retry))
            case .unauthorized:
                await gate.onError()
                if !job.reauthed {
                    SourceStore.shared.resetProvider(source.id)   // new provider re-reads / refreshes the token
                    retry(0, reauthed: true)
                } else {
                    await gate.suspend(for: 30 * 60)
                    giveUp("\(source.name)：登录已失效，请在「已添加的网盘」里重新登录")
                }
            case .forbidden:
                await gate.onError()
                db.markForbidden(job.dir)               // skip only this folder
                giveUp("\(name)：没有访问权限，已跳过")
            case .other:
                await gate.onError()
                giveUp("\(name)：\(error.localizedDescription)")
            }
        }
    }

    private func expand(_ job: ScanJob, _ children: [RemoteFile]) {
        if job.discLevel == 0 { videos += children.filter { !$0.isDir && $0.isVideo && !ScanRules.skipFile($0) }.count }
        else if children.contains(where: { !$0.isDir && $0.isVideo }) && job.discLevel == 2 { videos += 1 }
        defer { counts(videos, pending.count + max(0, inFlight.count - 1)) }
        for c in children where c.isDir {
            if job.discLevel == 1 {
                if c.name.lowercased() == "stream" { enqueue(dir: c, depth: job.depth + 1, type: .backgroundDelta, discLevel: 2) }
                continue
            }
            if job.discLevel == 2 { continue }
            if ScanRules.isDiscDir(c.name) {
                enqueue(dir: c, depth: job.depth + 1, type: .backgroundDelta, discLevel: c.name.lowercased() == "bdmv" ? 1 : 2)
                continue
            }
            guard job.depth + 1 <= ScanRules.maxDepth, !ScanRules.skipDir(c.name) else { continue }
            enqueue(dir: c, depth: job.depth + 1, type: .backgroundDelta)
        }
    }
}

// MARK: - Diagnostics

struct ScanDiagnosticsView: View {
    @ObservedObject private var center = ScanCenter.shared
    @EnvironmentObject var store: SourceStore

    var body: some View {
        List {
            let rows = store.sources.filter { center.stats[$0.id] != nil }
            if rows.isEmpty { Text("扫描一次后这里会显示每个文件源的请求统计。").foregroundStyle(.secondary) }
            ForEach(rows) { s in
                let st = center.stats[s.id] ?? GateStats()
                Section(s.name) {
                    LabeledContent("请求次数", value: "\(st.requests)")
                    LabeledContent("被限流（429）", value: "\(st.throttled)")
                    LabeledContent("其他错误", value: "\(st.errors)")
                    LabeledContent("平均耗时", value: "\(st.avgMs) ms")
                    LabeledContent("当前请求间隔", value: "\(st.delayMs) ms")
                    if let u = st.suspendedUntil {
                        LabeledContent("暂停到", value: u.formatted(date: .omitted, time: .shortened)).foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("扫描诊断")
        .task { await center.refreshStats() }
        .refreshable { await center.refreshStats() }
    }
}
