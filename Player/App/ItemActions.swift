import SwiftUI
import AMSMB2

// MARK: - Downloads (offline copies)

struct DownloadRecord: Codable, Identifiable, Hashable {
    var id: String            // LibraryFile.id == resume key (sourceId:fileId)
    var name: String
    var title: String
    var relPath: String       // under Application Support/Downloads
    var size: Int64
    var at = Date()
}

@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()
    @Published private(set) var records: [String: DownloadRecord] = [:]
    @Published private(set) var progress: [String: Double] = [:]     // active downloads
    @Published var lastError: String?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var queue: [(MediaSource, LibraryFile, String)] = []

    static let folder: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var u = d
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return d
    }()

    private init() {
        if let d = UserDefaults.standard.data(forKey: "downloads.v1"),
           let v = try? JSONDecoder().decode([String: DownloadRecord].self, from: d) {
            records = v.filter { FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent($0.value.relPath).path) }
        }
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(records) { UserDefaults.standard.set(d, forKey: "downloads.v1") }
    }

    func isDownloaded(_ id: String) -> Bool { records[id] != nil }
    func localURL(_ id: String) -> URL? { records[id].map { Self.folder.appendingPathComponent($0.relPath) } }
    var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.size } }

    /// Used by both players: a downloaded file plays from disk, keeping the same resume key.
    func playable(_ provider: SourceProvider, _ file: RemoteFile) async throws -> PlayableMedia {
        let key = provider.resumeKey(file)
        if let u = localURL(key) { return PlayableMedia(url: u, title: file.name, resumeKey: key) }
        return try await provider.playable(file)
    }

    func enqueue(_ files: [LibraryFile], title: String) {
        for f in files where records[f.id] == nil && progress[f.id] == nil {
            guard let src = SourceStore.shared.source(f.sourceId) else { continue }
            progress[f.id] = 0
            queue.append((src, f, title))
        }
        pump()
    }

    private func pump() {
        while tasks.count < 2, !queue.isEmpty {
            let (src, f, title) = queue.removeFirst()
            tasks[f.id] = Task { [weak self] in
                await self?.run(src, f, title)
                self?.tasks[f.id] = nil
                self?.pump()
            }
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
        queue.removeAll { $0.1.id == id }
        progress[id] = nil
        pump()
    }

    func delete(_ id: String) {
        if let u = localURL(id) { try? FileManager.default.removeItem(at: u) }
        records[id] = nil
        persist()
    }

    private func run(_ src: MediaSource, _ f: LibraryFile, _ title: String) async {
        let safe = f.file.name.replacingOccurrences(of: "/", with: "_")
        let rel = UUID().uuidString.prefix(8) + "-" + safe
        let dest = Self.folder.appendingPathComponent(String(rel))
        do {
            let provider = SourceStore.shared.provider(for: src)
            if let smb = provider as? SMBProvider {
                try await smb.download(f.file, to: dest) { [weak self] p in
                    Task { @MainActor in if self?.progress[f.id] != nil { self?.progress[f.id] = p } }
                }
            } else {
                let p = try await provider.playable(f.file)
                if p.url.isFileURL {
                    try FileManager.default.copyItem(at: p.url, to: dest)
                } else {
                    var req = URLRequest(url: p.url)
                    for (k, v) in p.headers { req.setValue(v, forHTTPHeaderField: k) }
                    let tmp = try await HTTPDownloader.download(req) { [weak self] frac in
                        Task { @MainActor in if self?.progress[f.id] != nil { self?.progress[f.id] = frac } }
                    }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                }
            }
            try Task.checkCancellation()
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? f.file.size
            records[f.id] = DownloadRecord(id: f.id, name: f.file.name, title: title, relPath: String(rel), size: size)
            persist()
        } catch {
            try? FileManager.default.removeItem(at: dest)
            if !(error is CancellationError) && !Task.isCancelled { lastError = "\(f.file.name) 下载失败：\(error.localizedDescription)" }
        }
        progress[f.id] = nil
    }
}

/// URLSession download with progress; cancels with the surrounding Task.
enum HTTPDownloader {
    final class Delegate: NSObject, URLSessionDownloadDelegate {
        let onProgress: (Double) -> Void
        var cont: CheckedContinuation<URL, Error>?
        init(_ p: @escaping (Double) -> Void) { onProgress = p }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
            if t > 0 { onProgress(Double(w) / Double(t)) }
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code >= 400 {
                cont?.resume(throwing: AppError.message("HTTP \(code)")); cont = nil; return
            }
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do { try FileManager.default.moveItem(at: location, to: keep); cont?.resume(returning: keep) }
            catch { cont?.resume(throwing: error) }
            cont = nil
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { cont?.resume(throwing: error); cont = nil }
        }
    }

    static func download(_ req: URLRequest, progress: @escaping (Double) -> Void) async throws -> URL {
        let d = Delegate(progress)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: cfg, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                d.cont = c
                task.resume()
            }
        } onCancel: { task.cancel() }
    }
}

extension SMBProvider {
    func download(_ file: RemoteFile, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let comps = file.path.split(separator: "/").map(String.init)
        let shareName = comps.first ?? ""
        let sub = comps.dropFirst().joined(separator: "/")
        let m = try await connectShareForDownload(shareName)
        try await m.downloadItem(atPath: sub, to: dest, progress: { done, total in
            if total > 0 { progress(Double(done) / Double(total)) }
            return !Task.isCancelled
        })
    }
}

// MARK: - 下载管理

struct DownloadsView: View {
    @ObservedObject private var dl = DownloadStore.shared
    var body: some View {
        List {
            if !dl.progress.isEmpty {
                Section("下载中") {
                    ForEach(Array(dl.progress.keys).sorted(), id: \.self) { k in
                        HStack {
                            ProgressView(value: dl.progress[k] ?? 0)
                            Text("\(Int((dl.progress[k] ?? 0) * 100))%").font(.caption.monospacedDigit())
                            Button(role: .destructive) { dl.cancel(k) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section {
                ForEach(dl.records.values.sorted { $0.at > $1.at }) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.title).font(.subheadline.bold())
                        Text(r.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("删除", role: .destructive) { dl.delete(r.id) } }
                }
            } header: {
                Text("已下载 · \(ByteCountFormatter.string(fromByteCount: dl.totalBytes, countStyle: .file))")
            } footer: {
                Text("下载的影片离线也能播放，播放进度和在线播放共用。左滑删除。")
            }
        }
        .navigationTitle("下载管理")
    }
}

// MARK: - 编辑信息

struct EditInfoView: View {
    let item: LibraryItem
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var tv = false
    @State private var results: [TMDBMatch] = []
    @State private var selected: Int?          // tmdb id; -1 = 原文件数据
    @State private var loading = false
    @State private var showRules = false
    @State private var saving = false
    @State private var pickSeason = 1
    @State private var pickEpisode = 1
    @State private var seasonCount: [Int: Int] = [:]     // tmdb id → 季数
    @State private var episodeCount: [String: Int] = [:]  // "id|季" → 集数
    @State private var pickerFor: NumberPick?
    enum NumberPick: Identifiable {
        case season(Int, Int), episode(Int, Int)            // (tmdb id, 总数)
        var id: String { switch self { case .season(let a, _): "s\(a)"; case .episode(let a, _): "e\(a)" } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text(item.files.first.map { $0.file.path.isEmpty ? $0.file.name : $0.file.path } ?? "")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    HStack(spacing: 10) {
                        HStack {
                            TextField("片名", text: $query).submitLabel(.search).onSubmit { Task { await search() } }
                            if !query.isEmpty {
                                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        Menu {
                            Button("电影") { tv = false; Task { await search() } }
                            Button("电视剧") { tv = true; Task { await search() } }
                        } label: {
                            HStack(spacing: 4) { Text(tv ? "电视剧" : "电影"); Image(systemName: "chevron.down").font(.caption) }
                                .foregroundStyle(.green)
                        }
                    }
                    choice(id: -1) {
                        Text("使用原文件数据").font(.body).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                    }
                    if loading { ProgressView().padding() }
                    ForEach(results, id: \.id) { m in
                        choice(id: m.id) {
                            HStack(alignment: .top, spacing: 12) {
                                PosterImage(url: m.poster, title: m.title)
                                    .frame(width: 70, height: 104)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Image(systemName: m.kind == "tv" ? "tv" : "film").foregroundStyle(.green)
                                        Text(m.title).font(.headline).lineLimit(2)
                                    }
                                    if let d = m.date ?? m.year.map(String.init) { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                                    if let o = m.overview, !o.isEmpty { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                    if m.kind == "tv" && selected == m.id { episodeRow(m) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if !loading && results.isEmpty && !query.isEmpty {
                        Text(AppSettings.shared.tmdbKey.isEmpty ? "请先在设置里填写 TMDB API Key" : "没有找到，换个名字或切换电影/电视剧试试")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } }
                ToolbarItem(placement: .primaryAction) { Button("命名规则") { showRules = true } }
                ToolbarItem(placement: .bottomBar) {
                    Button { save() } label: {
                        Text(saving ? "正在保存…" : "保存").bold().frame(maxWidth: .infinity)
                    }
                    .disabled(selected == nil || saving)
                }
            }
            .sheet(isPresented: $showRules) { NamingRulesView() }
            .sheet(item: $pickerFor) { p in
                switch p {
                case .season(let id, let n):
                    NumberGridPicker(title: "选择季", unit: "季", count: n, current: pickSeason) { v in
                        pickSeason = v; pickEpisode = 1; Task { await loadEpisodes(id, v) }
                    }
                case .episode(_, let n):
                    NumberGridPicker(title: "选择集", unit: "集", count: n, current: pickEpisode) { v in pickEpisode = v }
                }
            }
            .task {
                query = item.title
                tv = item.isTV
                selected = item.tmdbId ?? (library.overrides[item.id] != nil ? -1 : nil)
                let o = library.overrides[item.id]
                let f = item.files.first
                pickSeason = o?.season ?? f?.season ?? 1
                pickEpisode = o?.episode ?? f?.episode ?? 1
                await search()
            }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            let m = selected == -1 ? nil : results.first { $0.id == selected }
            if let m, m.kind == "tv" {
                await library.applyMatch(item.id, m, season: pickSeason, episode: pickEpisode)
            } else {
                await library.applyMatch(item.id, m)
            }
            dismiss()
        }
    }

    /// 剧集结果：第几季 / 第几集 / 确认
    @ViewBuilder private func episodeRow(_ m: TMDBMatch) -> some View {
        let seasons = max(seasonCount[m.id] ?? 0, pickSeason, 1)
        let eps = max(episodeCount["\(m.id)|\(pickSeason)"] ?? 0, pickEpisode, 1)
        HStack(spacing: 8) {
            Button { pickerFor = .season(m.id, seasons) } label: { chip("第\(pickSeason)季") }
            Button { pickerFor = .episode(m.id, eps) } label: { chip("第\(pickEpisode)集") }
            Button { save() } label: { chip(saving ? "保存中" : "确认") }
                .disabled(saving)
        }
        .padding(.top, 4)
        .task(id: m.id) {
            if seasonCount[m.id] == nil, let d = await TMDB.details(id: m.id, tv: true) { seasonCount[m.id] = d.seasonCount ?? 1 }
            await loadEpisodes(m.id, pickSeason)
        }
    }

    private func loadEpisodes(_ id: Int, _ sn: Int) async {
        let key = "\(id)|\(sn)"
        guard episodeCount[key] == nil else { return }
        let e = await TMDB.season(tvId: id, season: sn)
        episodeCount[key] = e.keys.max() ?? 0
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.medium)).foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(Color.green, in: RoundedRectangle(cornerRadius: 6))
    }

    private func choice<C: View>(id: Int, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            content()
            Image(systemName: selected == id ? "checkmark.circle.fill" : "circle")
                .font(.title2).foregroundStyle(selected == id ? .green : .secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(selected == id ? Color.green : Color.secondary.opacity(0.3), lineWidth: selected == id ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { selected = id }     // not a Button, so the 季/集/确认 controls inside stay tappable
    }

    private func search() async {
        let q = query.trimmed
        guard !q.isEmpty else { results = []; return }
        loading = true
        var r: [TMDBMatch] = []
        if let tid = TMDB.idInPath(q), let m = await TMDB.byId(tid, tv: tv) { r = [m] }
        else { r = await TMDB.searchList(q, tv: tv) }
        // keep the current match on top
        if let cur = item.tmdbId, let i = r.firstIndex(where: { $0.id == cur }), i > 0 { r.insert(r.remove(at: i), at: 0) }
        results = r
        loading = false
    }
}

/// 第几季 / 第几集 选择：独立的数字网格（长剧几百集也不会跳回顶部）
struct NumberGridPicker: View {
    let title: String
    let unit: String
    let count: Int
    let current: Int
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    private let cols = [GridItem(.adaptive(minimum: 58), spacing: 8)]
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(1...max(count, 1), id: \.self) { n in
                            Button { onPick(n); dismiss() } label: {
                                Text("\(n)").font(.body.monospacedDigit().weight(n == current ? .bold : .regular))
                                    .frame(maxWidth: .infinity).frame(height: 44)
                                    .foregroundStyle(n == current ? .white : .primary)
                                    .background(n == current ? Color.green : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain).id(n)
                        }
                    }
                    .padding(16)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle(title + " · 共 \(max(count, 1)) " + unit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct NamingRulesView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("电影") {
                    rule("电影/黎明到来的那一天 (2021)/黎明到来的那一天 (2021).mkv")
                    rule("电影/Inception (2010) 2160p.mkv")
                }
                Section("电视剧") {
                    rule("剧集/漫长的季节 (2023)/Season 01/漫长的季节 S01E01.mkv")
                    rule("剧集/漫长的季节/第1季/第01集.mp4")
                }
                Section("指定 TMDB 编号（最准）") {
                    rule("黎明到来的那一天 (2021) [tmdbid=839490]/…mkv")
                    Text("文件名或任一上级文件夹里写 [tmdbid=数字]、{tmdb-数字} 都可以，扫描时直接按编号匹配，不再按名字搜索。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("会被跳过") {
                    Text("以 . @ # $ 开头的文件夹、Sample / Extras / 回收站等文件夹，以及文件名含 sample 的视频。蓝光 BDMV、DVD VIDEO_TS 文件夹算一部影片。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("命名规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func rule(_ s: String) -> some View {
        Text(s).font(.footnote.monospaced())
    }
}
