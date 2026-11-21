import SwiftUI
import Combine

// MARK: - Palette

enum HomeStyle {
    static let bg = Color(red: 0.235, green: 0.215, blue: 0.205)
    static let card = Color.white.opacity(0.10)
    static let gradients: [[Color]] = [
        [Color(red: 0.62, green: 0.72, blue: 0.95), Color(red: 0.80, green: 0.70, blue: 0.95)],
        [Color(red: 0.98, green: 0.80, blue: 0.70), Color(red: 0.98, green: 0.88, blue: 0.80)],
        [Color(red: 0.62, green: 0.88, blue: 0.78), Color(red: 0.70, green: 0.80, blue: 0.95)],
        [Color(red: 0.98, green: 0.62, blue: 0.62), Color(red: 0.99, green: 0.75, blue: 0.62)],
        [Color(red: 0.80, green: 0.70, blue: 0.98), Color(red: 0.92, green: 0.72, blue: 0.95)],
        [Color(red: 0.70, green: 0.92, blue: 0.70), Color(red: 0.95, green: 0.95, blue: 0.62)],
        [Color(red: 0.55, green: 0.80, blue: 0.92), Color(red: 0.62, green: 0.90, blue: 0.80)],
        [Color(red: 0.98, green: 0.72, blue: 0.82), Color(red: 0.88, green: 0.76, blue: 0.98)],
    ]
}

// MARK: - Groupings

struct Shelf: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var items: [LibraryItem]
}

struct Bucket: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var items: [LibraryItem]
}

enum ShelfRoute: Hashable {
    case items(String, [String])          // title, item ids
    case buckets(String, [Bucket])
}

struct ContinueEntry: Identifiable {
    var id: String { file.id }
    var item: LibraryItem
    var file: LibraryFile
    var ms: Int32
    var total: Int32
    var at: Date
}

enum Groupings {
    static func isDoc(_ i: LibraryItem) -> Bool { (i.genres ?? []).contains { $0.contains("纪录") || $0 == "Documentary" } }
    static func isVariety(_ i: LibraryItem) -> Bool { (i.genres ?? []).contains { ["真人秀", "脱口秀", "Reality", "Talk"].contains($0) } }
    static func isOther(_ i: LibraryItem) -> Bool { category(i) == .other }
    static func isAnimation(_ i: LibraryItem) -> Bool { (i.genres ?? []).contains { $0 == "动画" || $0 == "Animation" || $0 == "動畫" } }

    /// 首页分类。用户长按 / 详情页 ⋯ 手动指定的分类优先，其次自动判断。
    enum Category: String, CaseIterable {
        case movie, animeMovie, tv, anime, shortDrama, variety, concert, doc, bl, other
        var name: String {
            switch self {
            case .movie: "电影"; case .animeMovie: "动画电影"; case .tv: "电视剧"; case .anime: "动画"
            case .variety: "综艺"; case .doc: "纪录片"; case .bl: "BL"; case .other: "其他"
            case .shortDrama: "短剧"; case .concert: "演唱会"
            }
        }
        var icon: String {
            switch self {
            case .movie: "film"; case .animeMovie: "sparkles.tv"; case .tv: "tv"; case .anime: "sparkles"
            case .variety: "music.mic"; case .doc: "globe.asia.australia"; case .bl: "heart"; case .other: "square.grid.2x2"
            case .shortDrama: "iphone"; case .concert: "music.note"
            }
        }
    }
    private static let catKey = "lib.category"
    static func categoryOverride(_ id: String) -> Category? {
        ((UserDefaults.standard.dictionary(forKey: catKey) as? [String: String])?[id]).flatMap(Category.init(rawValue:))
    }
    @MainActor static func setCategory(_ id: String, _ c: Category?) {
        var d = (UserDefaults.standard.dictionary(forKey: catKey) as? [String: String]) ?? [:]
        d[id] = c?.rawValue
        UserDefaults.standard.set(d, forKey: catKey)
        NotificationCenter.default.post(name: .categoryChanged, object: nil)
    }
    static func autoCategory(_ i: LibraryItem) -> Category {
        if autoBL(i) { return .bl }
        if matches(i, concertRegex) || (i.keywords ?? []).contains(where: { concertKeywords.contains($0) }) { return .concert }
        if matches(i, shortRegex) || (i.keywords ?? []).contains(where: { k in shortKeywords.contains(k) || (k.hasPrefix("net:") && shortPlatforms.contains { k.contains($0) }) }) { return .shortDrama }
        if i.tmdbId == nil { return .other }
        let anim = isAnimation(i)
        if i.isTV {
            if isVariety(i) { return .variety }
            if anim { return .anime }
            if isDoc(i) { return .doc }
            return .tv
        }
        if anim { return .animeMovie }
        if isDoc(i) { return .doc }
        return .movie
    }
    static func category(_ i: LibraryItem) -> Category { categoryOverride(i.id) ?? autoCategory(i) }
    static func isBL(_ i: LibraryItem) -> Bool { category(i) == .bl }

    private static let blKeywords: Set<String> = [
        "boys' love", "boys love", "boy's love", "boys' love (bl)", "bl", "bl drama", "bl series", "bl manga", "bl anime",
        "yaoi", "shounen ai", "shounen-ai", "shōnen-ai", "danmei", "gay romance", "gay love", "gay couple",
    ]
    private static let blRegex = try! NSRegularExpression(pattern: "(^|[^A-Za-z])BL([^A-Za-z]|$)|耽美|boys'? ?love|yaoi|腐剧", options: [.caseInsensitive])
    private static let concertKeywords: Set<String> = ["concert", "concert film", "live concert", "concert tour", "live performance", "music concert"]
    private static let shortKeywords: Set<String> = ["short drama", "vertical drama", "micro drama", "mini drama", "vertical series"]
    /// TMDB networks / production companies of short-drama apps (matched as substrings, lowercased)
    private static let shortPlatforms: [String] = [
        "红果", "hongguo", "reelshort", "dramabox", "shortmax", "goodshort", "flextv", "dramawave", "netshort",
        "reelflix", "moboreels", "topshort", "snackshort", "kalos tv", "minishort", "shorttv", "short tv", "dramareels",
        "河马剧场", "番茄短剧", "点众", "九州短剧", "麦芽短剧", "繁花剧场", "抖音短剧", "快手短剧", "微短剧",
    ]
    private static let concertRegex = try! NSRegularExpression(pattern: "演唱会|演唱會|音乐会|音樂會|巡演|巡回演唱|concert|live tour|world tour|in concert|コンサート|ライブ|콘서트", options: [.caseInsensitive])
    private static let shortRegex = try! NSRegularExpression(pattern: "短剧|短劇|微短剧|竖屏剧|小剧场", options: [.caseInsensitive])
    private static func matches(_ i: LibraryItem, _ re: NSRegularExpression) -> Bool {
        for s in [i.title, i.originalTitle ?? ""] + i.files.prefix(3).map({ $0.file.path.contains("/") ? $0.file.path : $0.file.name }) {
            if re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return true }
        }
        return false
    }
    private static func autoBL(_ i: LibraryItem) -> Bool {
        if (i.keywords ?? []).contains(where: { blKeywords.contains($0) || $0.contains("boys' love") || $0.contains("yaoi") }) { return true }
        // file / folder names (path-based drives keep folder names in the path)
        for f in i.files.prefix(3) {
            let s = f.file.path.contains("/") ? f.file.path : f.file.name
            if blRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return true }
        }
        return false
    }

    static func genres(_ items: [LibraryItem]) -> [Bucket] {
        var map: [String: [LibraryItem]] = [:]
        for i in items { for g in i.genres ?? [] { map[g, default: []].append(i) } }
        return map.map { Bucket(name: $0.key, items: $0.value) }.sorted { $0.items.count > $1.items.count }
    }

    static func ratings(_ items: [LibraryItem]) -> [Bucket] {
        let defs: [(String, (Double) -> Bool)] = [("9分", { $0 >= 9 }), ("8分", { $0 >= 8 && $0 < 9 }), ("7分", { $0 >= 7 && $0 < 8 }),
                                                  ("6分", { $0 >= 6 && $0 < 7 }), ("5分", { $0 >= 5 && $0 < 6 }), ("0-5分", { $0 > 0 && $0 < 5 })]
        return defs.compactMap { name, f in
            let xs = items.filter { f($0.rating ?? 0) }
            return xs.isEmpty ? nil : Bucket(name: name, items: xs)
        }
    }

    static func decades(_ items: [LibraryItem]) -> [Bucket] {
        let thisYear = Calendar.current.component(.year, from: Date())
        var map: [String: [LibraryItem]] = [:]
        var order: [String: Int] = [:]
        for i in items {
            guard let y = i.year else { continue }
            let key = y >= thisYear ? String(y) : "\(y / 10 * 10)年代"
            map[key, default: []].append(i)
            order[key] = y >= thisYear ? y * 10 : y / 10 * 10
        }
        return map.map { Bucket(name: $0.key, items: $0.value) }.sorted { (order[$0.name] ?? 0) > (order[$1.name] ?? 0) }
    }

    static func certifications(_ items: [LibraryItem]) -> [Bucket] {
        var map: [String: [LibraryItem]] = [:]
        for i in items { if let c = i.certification, !c.isEmpty { map[c, default: []].append(i) } }
        return map.map { Bucket(name: $0.key, items: $0.value) }.sorted { $0.items.count > $1.items.count }
    }

    static func continueWatching(_ items: [LibraryItem]) -> [ContinueEntry] {
        var out: [ContinueEntry] = []
        for it in items {
            for f in it.files {
                let ms = Resume.get(f.id)
                guard ms > 10_000, let at = Resume.playedAt(f.id) else { continue }
                out.append(ContinueEntry(item: it, file: f, ms: ms, total: Resume.total(f.id), at: at))
            }
        }
        // one entry per show: the most recent episode
        var seen = Set<String>()
        return out.sorted { $0.at > $1.at }.filter { seen.insert($0.item.id).inserted }
    }

    static func unwatched(_ items: [LibraryItem], marks: ItemMarks) -> [LibraryItem] {
        items.filter { it in
            !marks.watched.contains(it.id) && !it.files.contains { marks.watched.contains($0.id) || Resume.get($0.id) > 10_000 }
        }
    }
}

// MARK: - Home

/// Everything the home screen shows, computed once per library change (not on every render).
struct HomeShelves {
    var recent: [LibraryItem] = []
    var movies: [LibraryItem] = []
    var shows: [LibraryItem] = []
    var animeMovies: [LibraryItem] = []
    var anime: [LibraryItem] = []
    var bl: [LibraryItem] = []
    var shortDramas: [LibraryItem] = []
    var concerts: [LibraryItem] = []
    var docs: [LibraryItem] = []
    var variety: [LibraryItem] = []
    var other: [LibraryItem] = []
    var unwatched: [LibraryItem] = []
    var genres: [Bucket] = []
    var hero: [LibraryItem] = []
    var cont: [ContinueEntry] = []
    var nMovies = 0, nShows = 0, nOther = 0

    @MainActor static func build(_ items: [LibraryItem], marks: ItemMarks) -> HomeShelves {
        var h = HomeShelves()
        let recent = items.sorted { $0.added > $1.added }
        h.recent = recent
        var by: [Groupings.Category: [LibraryItem]] = [:]
        for it in recent { by[Groupings.category(it), default: []].append(it) }
        h.movies = by[.movie] ?? []
        h.animeMovies = by[.animeMovie] ?? []
        h.shows = by[.tv] ?? []
        h.anime = by[.anime] ?? []
        h.variety = by[.variety] ?? []
        h.docs = by[.doc] ?? []
        h.bl = by[.bl] ?? []
        h.shortDramas = by[.shortDrama] ?? []
        h.concerts = by[.concert] ?? []
        h.other = by[.other] ?? []
        h.unwatched = Groupings.unwatched(recent, marks: marks)
        h.genres = Groupings.genres(items)
        let withArt = recent.filter { $0.poster != nil || $0.backdrop != nil }
        h.hero = Array((withArt.isEmpty ? recent : withArt).prefix(8))
        h.cont = Groupings.continueWatching(items)
        h.nMovies = h.movies.count + h.animeMovies.count
        h.nShows = h.shows.count + h.anime.count + h.variety.count
        h.nOther = h.other.count
        return h
    }
}

/// Scan counters live in their own object so ticking numbers don't re-render the whole home screen.
@MainActor
final class ScanLive: ObservableObject {
    @Published var line: String?
    @Published var progress = ""
}

struct ScanCountLine: View {
    @ObservedObject var live: ScanLive
    var body: some View {
        if let line = live.line {
            Text(line).font(.footnote).foregroundStyle(.white.opacity(0.75)).monospacedDigit().multilineTextAlignment(.center)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sources: SourceStore
    @EnvironmentObject var router: PlaybackRouter
    @ObservedObject private var marks = ItemMarks.shared
    @State private var showFolders = false
    @State private var resumeTick = 0
    @State private var path = NavigationPath()
    @State private var shelves = HomeShelves()

    private func rebuild() { shelves = HomeShelves.build(library.items, marks: marks) }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                HomeStyle.bg.ignoresSafeArea()
                if library.items.isEmpty && !library.scanning {
                    emptyState.padding(.top, 140)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            HeroCarousel(items: shelves.hero)
                            banners
                            continueRow
                            shelfRow("最近添加", shelves.recent)
                            shelfRow("电影", shelves.movies)
                            shelfRow("动画电影", shelves.animeMovies)
                            shelfRow("电视剧", shelves.shows)
                            shelfRow("动画", shelves.anime)
                            shelfRow("综艺", shelves.variety)
                            shelfRow("纪录片", shelves.docs)
                            shelfRow("短剧", shelves.shortDramas)
                            shelfRow("演唱会", shelves.concerts)
                            shelfRow("BL", shelves.bl)
                            shelfRow("其他", shelves.other)
                            shelfRow("未观看", shelves.unwatched)
                            bucketRow("类型", shelves.genres)
                            stats
                        }
                        .padding(.bottom, 120)
                    }
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea(edges: .top)
                    .refreshable { await library.scan() }
                }
                topBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: LibraryItem.self) { DetailView(itemId: $0.id) }
            .navigationDestination(for: ShelfRoute.self) { r in
                switch r {
                case .items(let t, let ids): ItemGridView(title: t, ids: ids)
                case .buckets(let t, let b): BucketListView(title: t, buckets: b)
                }
            }
            .sheet(isPresented: $showFolders) { LibraryFoldersView() }
            .onReceive(NotificationCenter.default.publisher(for: .resumeChanged).throttle(for: .seconds(3), scheduler: RunLoop.main, latest: true)) { _ in resumeTick += 1; rebuild() }
            .onReceive(library.$items.debounce(for: .seconds(0.8), scheduler: RunLoop.main)) { _ in rebuild() }
            .onReceive(NotificationCenter.default.publisher(for: .categoryChanged)) { _ in rebuild() }
            .onReceive(marks.objectWillChange.debounce(for: .seconds(0.3), scheduler: RunLoop.main)) { _ in rebuild() }
            .onAppear { rebuild() }
            .task { await library.enrich() }
        }
    }


    // MARK: top bar

    private var topBar: some View {
        HStack {
            if library.scanning {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").foregroundStyle(.green)
                    Text("数据同步中").font(.subheadline.weight(.medium))
                    ProgressView().controlSize(.small).tint(.green)
                }
                .padding(.horizontal, 16).frame(height: 44)
                .glass(in: Capsule())
                .transition(.opacity)
            }
            Spacer()
            Menu {
                Button { Task { await library.scan(force: true) } } label: { Label("重新扫描文件", systemImage: "arrow.clockwise") }
                Button { showFolders = true } label: { Label("管理媒体库文件夹", systemImage: "folder.badge.gearshape") }
            } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
            }
            .glass(in: Circle(), interactive: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .animation(.easeInOut, value: library.scanning)
    }

    @ViewBuilder private var banners: some View {
        if let r = library.lastResult, !library.scanning, r.hasPrefix("扫描失败") || r.contains("没在") {
            Label(r, systemImage: "exclamationmark.triangle").font(.footnote).padding(12)
                .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .onTapGesture { library.lastResult = nil }
        }
        if settings.tmdbKey.isEmpty {
            Label("在设置里填写 TMDB API Key，即可自动获取海报、类型和评分", systemImage: "info.circle")
                .font(.footnote).padding(12)
                .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
        }
    }

    // MARK: rows

    private func header(_ title: String, count: Int, route: ShelfRoute) -> some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            NavigationLink(value: route) {
                HStack(spacing: 3) { Text("全部 · \(count)"); Image(systemName: "chevron.right") }
                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var continueRow: some View {
        let list = shelves.cont
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header("继续观看", count: list.count, route: .items("继续观看", list.map { $0.item.id }))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(list) { e in
                            Button { play(e.file, e.item) } label: { ContinueCard(entry: e) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("从头播放") { Resume.clear(e.file.id); ItemMarks.shared.watched.remove(e.file.id); play(e.file, e.item) }
                                    Button("从继续观看中移除", role: .destructive) { Resume.clear(e.file.id); ItemMarks.shared.watched.remove(e.file.id) }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder private func shelfRow(_ title: String, _ items: [LibraryItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header(title, count: items.count, route: .items(title, items.map(\.id)))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items.prefix(30)) { it in
                            NavigationLink(value: it) { PosterTile(item: it) }.buttonStyle(.plain).categoryMenu(it)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder private func bucketRow(_ title: String, _ buckets: [Bucket]) -> some View {
        if !buckets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header(title, count: buckets.count, route: .buckets(title, buckets))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(buckets.enumerated()), id: \.element.id) { i, b in
                            NavigationLink(value: ShelfRoute.items(b.name, b.items.map(\.id))) {
                                BucketCard(bucket: b, colors: HomeStyle.gradients[(i + title.count) % HomeStyle.gradients.count])
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var stats: some View {
        let movies = shelves.nMovies, shows = shelves.nShows, other = shelves.nOther
        return VStack(spacing: 14) {
            HStack(spacing: 10) {
                statTile("电影", movies, Color(red: 0.42, green: 0.45, blue: 0.85), "film")
                statTile("电视剧", shows, Color(red: 0.30, green: 0.62, blue: 0.45), "tv")
                statTile("其他", other, Color(red: 0.62, green: 0.48, blue: 0.32), "square.grid.2x2")
            }
            if let d = library.lastScan {
                Text("上次更新时间：\(d.formatted(.dateTime.year().month().day().hour().minute()))")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
            ScanCountLine(live: library.live)
            Button { Task { await library.scan() } } label: {
                HStack(spacing: 8) {
                    if library.scanning { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    Text(library.scanning ? "正在扫描…" : "重新扫描文件")
                }
                .font(.subheadline).padding(.horizontal, 22).frame(height: 40)
                .background(HomeStyle.card, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(library.scanning)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private func statTile(_ title: String, _ n: Int, _ color: Color, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Text("\(n)").font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(width: 92, height: 58, alignment: .leading)
        .padding(.leading, 12)
        .background(alignment: .trailing) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.white.opacity(0.15)).padding(.trailing, 6)
        }
        .background(color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 52)).foregroundStyle(.pink)
            Text("媒体库还是空的").font(.title3.bold())
            Text("到「文件源」或「服务器」里添加 SMB、WebDAV、Emby、Jellyfin 或网盘，长按任意文件夹或视频选择「添加到媒体库」，即可生成海报墙。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding()
    }

    private func play(_ f: LibraryFile, _ item: LibraryItem) {
        guard let src = sources.source(f.sourceId) else { return }
        let t = item.isTV ? "\(item.title) 第\(f.episode ?? 0)集" : item.title
        router.play(PlayRequest(source: src, file: f.file, siblings: [], title: t, extraSubtitles: f.subtitles))
    }
}

// MARK: - Hero carousel

struct HeroCarousel: View {
    let items: [LibraryItem]
    @State private var page = 0
    @State private var logos: [String: URL] = [:]
    @State private var metas: [String: TMDBDetails] = [:]

    var body: some View {
        if !items.isEmpty {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .bottom) {
                    TabView(selection: $page) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                            NavigationLink(value: it) { slide(it, width: w) }
                                .buttonStyle(.plain)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    HStack(spacing: 7) {
                        ForEach(items.indices, id: \.self) { i in
                            Circle().fill(.white.opacity(i == page ? 0.95 : 0.35)).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .frame(height: 600)
            .task(id: items.map(\.id)) {
                for it in items where metas[it.id] == nil {
                    if let id = it.tmdbId, let d = await TMDB.details(id: id, tv: it.isTV) { metas[it.id] = d }
                }
            }
            .task(id: items.count) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    if items.count > 1 { withAnimation(.easeInOut(duration: 0.6)) { page = (page + 1) % items.count } }
                }
            }
        }
    }

    private func slide(_ it: LibraryItem, width: CGFloat) -> some View {
        let d = metas[it.id]
        return ZStack(alignment: .bottom) {
            PosterImage(url: d?.posterHi ?? it.poster ?? it.backdrop, title: "")
                .frame(width: width, height: 600)
                .clipped()
                .overlay(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.45),
                                                .init(color: HomeStyle.bg.opacity(0.85), location: 0.78), .init(color: HomeStyle.bg, location: 1)],
                                        startPoint: .top, endPoint: .bottom))
            VStack(spacing: 10) {
                if let logo = d?.logo {
                    AsyncImage(url: logo) { ph in
                        if let i = ph.image { i.resizable().scaledToFit() } else { title(it) }
                    }
                    .frame(maxWidth: width * 0.7, maxHeight: 110)
                    .shadow(color: .black.opacity(0.4), radius: 6)
                } else {
                    title(it)
                }
                meta(it, d)
                if let o = (d?.overview?.isEmpty == false ? d?.overview : it.overview), !o.isEmpty {
                    Text(o).font(.footnote).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3).multilineTextAlignment(.leading)
                        .padding(.horizontal, 18)
                }
            }
            .padding(.bottom, 26)
        }
        .frame(width: width, height: 600)
        .contentShape(Rectangle())
    }

    private func title(_ it: LibraryItem) -> some View {
        Text(it.title).font(.system(size: 34, weight: .heavy)).multilineTextAlignment(.center).lineLimit(2)
            .padding(.horizontal, 24).shadow(color: .black.opacity(0.5), radius: 6)
    }

    private func meta(_ it: LibraryItem, _ d: TMDBDetails?) -> some View {
        var parts: [String] = []
        if let y = it.year { parts.append(String(y)) }
        if let c = d?.countries.first ?? it.countries?.first { parts.append(c) }
        if let g = (d?.genres ?? it.genres)?.first { parts.append(g) }
        let ps = parts
        return HStack(spacing: 7) {
            if let r = it.rating, r > 0 {
                HStack(spacing: 2) { Image(systemName: "star.fill").foregroundStyle(.yellow); Text(String(format: "%.1f", r)) }
            }
            ForEach(Array(ps.enumerated()), id: \.offset) { i, p in
                if i > 0 || (it.rating ?? 0) > 0 { Text("|").foregroundStyle(.white.opacity(0.5)) }
                Text(p)
            }
        }
        .font(.footnote.weight(.semibold))
        .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

// MARK: - Cards

extension Notification.Name { static let categoryChanged = Notification.Name("lib.categoryChanged") }

/// 「移到分类」菜单：长按海报，或详情页 ⋯
struct CategoryMenuItems: View {
    let item: LibraryItem
    var flat = false      // long-press menu: list categories directly (a nested submenu draws a second panel behind it)
    @State private var tick = 0
    var body: some View {
        let _ = tick
        let cur = Groupings.category(item)
        let manual = Groupings.categoryOverride(item.id) != nil
        if flat {
            Section("移到分类（当前：\(cur.name)）") { items(cur: cur, manual: manual) }
                .onReceive(NotificationCenter.default.publisher(for: .categoryChanged)) { _ in tick += 1 }
        } else {
            Menu { items(cur: cur, manual: manual) } label: { Label("移到分类（当前：\(cur.name)）", systemImage: "folder.badge.gearshape") }
                .onReceive(NotificationCenter.default.publisher(for: .categoryChanged)) { _ in tick += 1 }
        }
    }
    @ViewBuilder private func items(cur: Groupings.Category, manual: Bool) -> some View {
            ForEach(Groupings.Category.allCases, id: \.self) { c in
                Button { Groupings.setCategory(item.id, c) } label: {
                    if c == cur { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            if manual {
                Divider()
                Button { Groupings.setCategory(item.id, nil) } label: {
                    Label("恢复自动分类（\(Groupings.autoCategory(item).name)）", systemImage: "arrow.uturn.backward")
                }
            }
    }
}

extension View {
    func categoryMenu(_ item: LibraryItem) -> some View {
        contextMenu { CategoryMenuItems(item: item, flat: true) }
    }
}

struct PosterTile: View {
    let item: LibraryItem
    var width: CGFloat = 112
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PosterImage(url: item.poster, title: item.title)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let r = item.rating, r > 0 {
                        Text(String(format: "%.1f", r)).font(.caption.weight(.heavy)).foregroundStyle(.white)
                            .shadow(color: .black, radius: 3).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if ItemMarks.shared.watched.contains(item.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).shadow(radius: 2).padding(6)
                    }
                }
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(item.isTV ? "共\(max(1, item.seasons.count))季" : (item.year.map { String($0) } ?? "电影"))
                .font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: width)
        .contentShape(Rectangle())        // taps land on this tile only
    }
}

struct ContinueCard: View {
    let entry: ContinueEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                PosterImage(url: entry.file.still ?? entry.item.backdrop ?? entry.item.poster, title: "")
                    .frame(width: 214, height: 120).clipped().contentShape(Rectangle())
                Image(systemName: "play.fill").font(.title3).foregroundStyle(.white)
                    .frame(width: 46, height: 46).glass(in: Circle())
                VStack(spacing: 4) {
                    Spacer()
                    if entry.total > 0 {
                        Text("\(PlayerController.fmt(entry.ms)) / \(PlayerController.fmt(entry.total))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.white).shadow(radius: 2)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(.white).frame(width: g.size.width * CGFloat(min(1, Double(entry.ms) / Double(max(1, entry.total)))))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(10)
            }
            .frame(width: 214, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(entry.item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            if entry.item.isTV {
                Text("第 \(entry.file.season ?? 1) 季 第 \(entry.file.episode ?? 0) 集").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 214)
    }
}

struct BucketCard: View {
    let bucket: Bucket
    let colors: [Color]
    var body: some View {
        let posters = Array(bucket.items.compactMap(\.poster).prefix(3))
        ZStack(alignment: .bottom) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            ZStack {
                ForEach(Array(Array(posters.enumerated()).reversed()), id: \.offset) { i, u in
                    PosterImage(url: u, title: "")
                        .frame(width: 58, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 2)
                        .rotationEffect(.degrees(Double(i - 1) * -7))
                        .offset(x: CGFloat(i - 1) * 40, y: i == 1 ? -26 : -22)
                }
                if posters.isEmpty {
                    RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.6)).frame(width: 58, height: 84).offset(y: -24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(bucket.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(bucket.items.count)").font(.caption.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(Color(white: 0.15))
            .padding(.horizontal, 12).padding(.bottom, 9)
        }
        .frame(width: 168, height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - "全部" pages

struct ItemGridView: View {
    let title: String
    let ids: [String]
    @EnvironmentObject var library: LibraryStore
    @State private var sort = 0

    private var items: [LibraryItem] {
        let byId = Dictionary(library.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let xs = ids.compactMap { byId[$0] }
        switch sort {
        case 1: return xs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case 2: return xs.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case 3: return xs.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        default: return xs
        }
    }

    var body: some View {
        ZStack {
            HomeStyle.bg.ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)], spacing: 18) {
                    ForEach(items) { it in
                        NavigationLink(value: it) { PosterTile(item: it, width: 104) }.buttonStyle(.plain).categoryMenu(it)
                    }
                }
                .padding(16)
                .padding(.bottom, 100)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $sort) {
                        Text("默认").tag(0); Text("名称").tag(1); Text("评分").tag(2); Text("年份").tag(3)
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .foregroundStyle(.white)
    }
}

struct BucketListView: View {
    let title: String
    let buckets: [Bucket]
    var body: some View {
        ZStack {
            HomeStyle.bg.ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(Array(buckets.enumerated()), id: \.element.id) { i, b in
                        NavigationLink(value: ShelfRoute.items(b.name, b.items.map(\.id))) {
                            BucketCard(bucket: b, colors: HomeStyle.gradients[(i + title.count) % HomeStyle.gradients.count])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .padding(.bottom, 100)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

// MARK: - Search tab

struct LibrarySearchView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var q = ""

    private var results: [LibraryItem] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        return library.items.filter {
            $0.title.localizedCaseInsensitiveContains(t) || ($0.originalTitle ?? "").localizedCaseInsensitiveContains(t)
                || ($0.genres ?? []).contains { $0.localizedCaseInsensitiveContains(t) }
                || $0.files.contains { $0.file.name.localizedCaseInsensitiveContains(t) }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HomeStyle.bg.ignoresSafeArea()
                ScrollView {
                    if q.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("类型").font(.title3.bold())
                            FlowChips(items: Groupings.genres(library.items).map(\.name)) { q = $0 }
                        }
                        .padding(16)
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: q).padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)], spacing: 18) {
                            ForEach(results) { it in
                                NavigationLink(value: it) { PosterTile(item: it, width: 104) }.buttonStyle(.plain).categoryMenu(it)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $q, prompt: "影片、剧集、类型、文件名")
            .navigationDestination(for: LibraryItem.self) { DetailView(itemId: $0.id) }
            .navigationDestination(for: ShelfRoute.self) { r in
                switch r {
                case .items(let t, let ids): ItemGridView(title: t, ids: ids)
                case .buckets(let t, let b): BucketListView(title: t, buckets: b)
                }
            }
        }
    }
}

struct FlowChips: View {
    let items: [String]
    let tap: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { s in
                Button { tap(s) } label: {
                    Text(s).font(.subheadline).lineLimit(1).padding(.horizontal, 14).frame(height: 38).frame(maxWidth: .infinity)
                        .background(HomeStyle.card, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
