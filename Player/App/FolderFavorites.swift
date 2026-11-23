import SwiftUI

/// Folders inside drives the user starred; the 文件源 tab shows only these.
struct FavoriteFolder: Codable, Identifiable, Hashable {
    var id: String { sourceId.uuidString + ":" + (dir?.id ?? "__root__") }
    var sourceId: UUID
    var dir: RemoteFile?
    var title: String
    var added = Date()
}

@MainActor
final class FolderFavorites: ObservableObject {
    static let shared = FolderFavorites()
    @Published private(set) var items: [FavoriteFolder] = []
    private let key = "folderFavorites.v1"

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode([FavoriteFolder].self, from: d) { items = v }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
    private func fid(_ s: MediaSource, _ d: RemoteFile?) -> String { s.id.uuidString + ":" + (d?.id ?? "__root__") }

    func contains(_ s: MediaSource, _ d: RemoteFile?) -> Bool { items.contains { $0.id == fid(s, d) } }
    func toggle(_ s: MediaSource, _ d: RemoteFile?) {
        if contains(s, d) { items.removeAll { $0.id == fid(s, d) }; unlink(s.id, d) }
        else {
            items.append(FavoriteFolder(sourceId: s.id, dir: d, title: d?.name ?? s.name))
            // A new favourite also goes into the media library and gets scanned right away (only the new folder).
            if !s.kind.isMediaServer {
                if let d { LibraryStore.shared.addFolder(source: s, dir: d) } else { LibraryStore.shared.addRoot(source: s) }
            }
        }
        save()
    }
    func remove(_ f: FavoriteFolder) { items.removeAll { $0.id == f.id }; unlink(f.sourceId, f.dir); save() }
    /// 取消收藏 also takes that folder (and its films) out of the media library.
    private func unlink(_ sid: UUID, _ d: RemoteFile?) {
        let lib = LibraryStore.shared
        for f in lib.folders where f.sourceId == sid && (d.map { f.dir.id == $0.id } ?? (f.dir.meta["root"] == "1")) {
            lib.removeFolder(f)
        }
    }
    func move(from: IndexSet, to: Int) { items.move(fromOffsets: from, toOffset: to); save() }
    func purge(source: UUID) { items.removeAll { $0.sourceId == source }; save() }
}

extension Notification.Name { static let openSourceManager = Notification.Name("openSourceManager") }

enum SourceRoute: Hashable { case manage, addList, added }

/// 文件源 tab: starred folders only.
struct FavoriteSourcesView: View {
    @EnvironmentObject var store: SourceStore
    @ObservedObject private var favs = FolderFavorites.shared
    @State private var path = NavigationPath()
    @State private var editing: MediaSource?
    @EnvironmentObject var library: LibraryStore
    @State private var toast: String?
    @State private var editItem: LibraryItem?
    @State private var pickList: [LibraryItem] = []
    @State private var showPick = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AuroraBackground()
                if favs.items.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "star.square.on.square").font(.system(size: 46)).foregroundStyle(.secondary)
                        Text("还没有收藏的文件夹").font(.headline)
                        Text("点右下角的 ＋，进入已添加的网盘，在想看的电影、电视剧文件夹上长按选「收藏」，或在文件夹里点右上角 ⋯ 收藏。")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                        Button { path.append(SourceRoute.manage) } label: { Label("添加 / 管理网盘", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(favs.items) { f in
                            if let s = store.source(f.sourceId) {
                                NavigationLink(value: BrowseTarget(source: s, dir: f.dir)) {
                                    HStack(spacing: 14) {
                                        Image(systemName: "folder.fill").font(.title2).foregroundStyle(s.kind.tint)
                                            .frame(width: 46, height: 46)
                                            .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: s.kind.tint.opacity(0.25))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(f.title).font(.headline).lineLimit(1)
                                            Label(s.name, systemImage: s.kind.icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        Button { favs.remove(f); toast = "已取消收藏，并从媒体库移除" } label: {
                                            Image(systemName: "star.fill").foregroundStyle(.yellow).frame(width: 44, height: 44).contentShape(Rectangle())
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("取消收藏")
                                    }
                                    .padding(.vertical, 4)
                                }
                                .listRowBackground(Color.clear)
                                .swipeActions {
                                    Button(role: .destructive) { favs.remove(f) } label: { Label("取消收藏", systemImage: "star.slash") }
                                }
                                .contextMenu {
                                    Button {
                                        toast = "正在重新扫描 \(f.title)…"
                                        Task { await library.rescanDir(source: s, dir: f.dir); toast = "已重新扫描 \(f.title)" }
                                    } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                                    Button {
                                        let xs = library.items(under: s, dir: f.dir)
                                        if xs.count == 1 { editItem = xs[0] }
                                        else if xs.isEmpty { toast = "这个文件夹里还没有扫进媒体库的影片" }
                                        else { pickList = xs; showPick = true }
                                    } label: { Label("编辑匹配", systemImage: "square.and.pencil") }
                                    Button(role: .destructive) { favs.remove(f); toast = "已取消收藏，并从媒体库移除" } label: { Label("取消收藏", systemImage: "star.slash") }
                                }
                            }
                        }
                        .onMove { favs.move(from: $0, to: $1) }
                    }
                    .scrollContentBackground(.hidden)
                }
                if let t = toast {
                    VStack { Spacer(); Text(t).font(.footnote).padding(.horizontal, 16).padding(.vertical, 10).glass(in: Capsule()).padding(.bottom, 90) }
                        .task(id: t) { try? await Task.sleep(nanoseconds: 2_500_000_000); if toast == t { toast = nil } }
                }
            }
            .sheet(item: $editItem) { EditInfoView(item: $0).environmentObject(library) }
            .confirmationDialog("选择要编辑匹配的影片", isPresented: $showPick, titleVisibility: .visible) {
                ForEach(pickList.prefix(15)) { it in Button(it.year.map { "\(it.title) (\($0))" } ?? it.title) { editItem = it } }
            }
            .navigationTitle("文件源")
            .navigationDestination(for: BrowseTarget.self) {
                FolderView(target: $0)
                    .onAppear { FavoritesNav.shared.enter() }
                    .onDisappear { FavoritesNav.shared.leave() }
            }
            .navigationDestination(for: SourceRoute.self) { r in
                switch r {
                case .manage: SourceManagerView(path: $path)
                case .addList: AddSourceListView(editing: $editing)
                case .added: AddedSourcesView(editing: $editing)
                }
            }
            .toolbar { if !favs.items.isEmpty { ToolbarItem(placement: .topBarTrailing) { EditButton() } } }
            .sheet(item: $editing) { SourceEditor(source: $0) }
            .onReceive(NotificationCenter.default.publisher(for: .openSourceManager)) { _ in
                if path.isEmpty { path.append(SourceRoute.manage) }
            }
        }
    }
}

struct SourceManagerView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject var store: SourceStore
    var body: some View {
        List {
            Section {
                NavigationLink(value: SourceRoute.addList) {
                    Label { VStack(alignment: .leading) { Text("添加文件源"); Text("所有支持的网盘和共享").font(.caption).foregroundStyle(.secondary) } }
                    icon: { Image(systemName: "plus.circle.fill").foregroundStyle(.pink) }
                }
                NavigationLink(value: SourceRoute.added) {
                    Label { VStack(alignment: .leading) { Text("已添加的网盘"); Text("\(store.sources.filter { !$0.kind.isMediaServer }.count) 个，可修改、删除、浏览并收藏文件夹").font(.caption).foregroundStyle(.secondary) } }
                    icon: { Image(systemName: "externaldrive.fill.badge.checkmark").foregroundStyle(.blue) }
                }
            }
        }
        .navigationTitle("文件源管理")
    }
}

struct AddSourceListView: View {
    @Binding var editing: MediaSource?
    var body: some View {
        List {
            let kinds = SourceKind.allCases.filter { $0 != .local && !$0.isMediaServer }
            Section("网盘") {
                ForEach(kinds.filter { ![.smb, .webdav].contains($0) }) { row($0) }
            }
            Section("局域网 / 协议") {
                ForEach(kinds.filter { [.smb, .webdav].contains($0) }) { row($0) }
            }
        }
        .navigationTitle("添加文件源")
    }
    private func row(_ k: SourceKind) -> some View {
        Button { editing = MediaSource(kind: k, name: k.title) } label: {
            HStack { Label(k.title, systemImage: k.icon).foregroundStyle(.primary); Spacer(); Image(systemName: "plus").foregroundStyle(.secondary) }
        }
        .tint(k.tint)
    }
}

struct AddedSourcesView: View {
    @Binding var editing: MediaSource?
    @EnvironmentObject var store: SourceStore
    var body: some View {
        let list = store.sources.filter { !$0.kind.isMediaServer }
        List {
            if list.isEmpty { Text("还没有添加网盘").foregroundStyle(.secondary) }
            ForEach(list) { s in
                NavigationLink(value: BrowseTarget(source: s, dir: nil)) {
                    HStack(spacing: 12) {
                        Image(systemName: s.kind.icon).foregroundStyle(s.kind.tint).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            Text(s.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !s.isLoggedIn { Text("未登录").font(.caption2).foregroundStyle(.orange) }
                    }
                }
                .swipeActions {
                    if s.kind != .local {
                        Button(role: .destructive) { FolderFavorites.shared.purge(source: s.id); store.remove(s) } label: { Label("删除", systemImage: "trash") }
                        Button { editing = s } label: { Label("修改", systemImage: "pencil") }.tint(.blue)
                    }
                }
                .contextMenu {
                    if s.kind != .local {
                        Button { editing = s } label: { Label("修改", systemImage: "pencil") }
                        Button(role: .destructive) { FolderFavorites.shared.purge(source: s.id); store.remove(s) } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("已添加的网盘")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: SourceRoute.addList) { Image(systemName: "plus") }
            }
        }
    }
}

// MARK: - Search inside starred folders (文件源 › folder › 🔍)

/// True while a starred folder is open in the 文件源 tab: the tab bar's ＋ turns into a search for starred folders only.
@MainActor
final class FavoritesNav: ObservableObject {
    static let shared = FavoritesNav()
    @Published private(set) var inFolder = false
    private var depth = 0
    func enter() { depth += 1; update() }
    func leave() { depth = max(0, depth - 1); update() }
    private func update() {
        let v = depth > 0
        if v != inFolder { inFolder = v }
    }
}

struct FavoriteFileHit: Identifiable {
    var id: String { source.id.uuidString + ":" + file.id }
    var source: MediaSource
    var file: RemoteFile
    var siblings: [RemoteFile]
    var place: String
}

extension ScanCenter {
    /// Make sure a starred folder's tree is in the snapshot DB (lists only dirs never seen or past their TTL; paced per source).
    func index(_ s: MediaSource, _ dir: RemoteFile?, progress: @escaping (String) -> Void) async {
        guard !s.kind.isMediaServer else { return }
        let run = CrawlRunHandle.make(center: self, source: s, db: db(s.id), gate: gate(s), progress: progress)
        await run(dir)
        db(s.id).flush()
    }

    /// Name search over the snapshot trees of the starred folders only (no network).
    func searchFavorites(_ q: String, _ favs: [FavoriteFolder]) -> [FavoriteFileHit] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        var out: [FavoriteFileHit] = []
        var seen = Set<String>()
        for fav in favs {
            guard let s = SourceStore.shared.source(fav.sourceId) else { continue }
            let db = db(s.id)
            var stack: [(String, String, Int)] = [(SnapshotDB.key(fav.dir), fav.title, 0)]
            while let top = stack.popLast(), out.count < 400 {
                let (key, place, depth) = top
                guard seen.insert(s.id.uuidString + key).inserted, let snap = db[key] else { continue }
                for f in snap.children {
                    if f.isDir {
                        if ScanRules.skipDir(f.name) { continue }
                        if f.name.localizedCaseInsensitiveContains(t) {
                            out.append(FavoriteFileHit(source: s, file: f, siblings: [], place: place))
                        }
                        if depth < 12 { stack.append((f.id, place + " › " + f.name, depth + 1)) }
                    } else if f.isVideo, f.name.localizedCaseInsensitiveContains(t) {
                        out.append(FavoriteFileHit(source: s, file: f, siblings: snap.children, place: place))
                    }
                }
            }
        }
        return out.sorted { a, b in
            if a.file.isDir != b.file.isDir { return a.file.isDir }
            return a.file.name.localizedStandardCompare(b.file.name) == .orderedAscending
        }
    }
}

struct FavoriteFilesSearchView: View {
    @EnvironmentObject var router: PlaybackRouter
    @ObservedObject private var favs = FolderFavorites.shared
    @State private var q = ""
    @State private var hits: [FavoriteFileHit] = []
    @State private var indexing: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                List {
                    if let indexing {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text(indexing).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                            .listRowBackground(Color.clear)
                    }
                    if q.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("只搜索「文件源」里收藏的文件夹，不包含媒体库刮削的影片。")
                            .font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                    } else if hits.isEmpty && indexing == nil {
                        ContentUnavailableView.search(text: q).listRowBackground(Color.clear)
                    }
                    ForEach(hits) { h in
                        if h.file.isDir {
                            NavigationLink(value: BrowseTarget(source: h.source, dir: h.file)) { row(h) }
                                .listRowBackground(Color.clear)
                        } else {
                            Button { router.play(PlayRequest(source: h.source, file: h.file, siblings: h.siblings)) } label: { row(h) }
                                .buttonStyle(.plain).listRowBackground(Color.clear)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("搜索收藏")
            .navigationDestination(for: BrowseTarget.self) { FolderView(target: $0) }
            .searchable(text: $q, prompt: "收藏文件夹里的文件名")
            .onChange(of: q) { _, _ in refresh() }
            .task { await buildIndex() }
        }
    }

    private func row(_ h: FavoriteFileHit) -> some View {
        HStack(spacing: 12) {
            Image(systemName: h.file.isDir ? "folder.fill" : "film").font(.title3)
                .foregroundStyle(h.file.isDir ? h.source.kind.tint : .secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(h.file.name).lineLimit(2)
                Text(h.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func refresh() { hits = ScanCenter.shared.searchFavorites(q, favs.items) }

    private func buildIndex() async {
        for f in favs.items {
            guard let s = SourceStore.shared.source(f.sourceId) else { continue }
            indexing = "正在读取 \(f.title)…"
            await ScanCenter.shared.index(s, f.dir) { msg in indexing = msg }
            refresh()
        }
        indexing = nil
        refresh()
    }
}
