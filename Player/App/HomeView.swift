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
    case bl
    case collection(String, [String])     // TMDB movie collection: name, item ids
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
        case movie, animeMovie, tv, shortDrama, anime, variety, doc, concert, bl, other
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
    // In-memory copies: reading UserDefaults per item per rebuild was a big part of the scan-time lag.
    nonisolated(unsafe) private static var catCache: [String: String]?
    nonisolated(unsafe) private static var blCache: [String: String]?
    nonisolated(unsafe) private static var autoMemo: [String: (String, Category)] = [:]
    private static let memoLock = NSLock()
    private static func catDict() -> [String: String] {
        memoLock.lock(); defer { memoLock.unlock() }
        if let c = catCache { return c }
        let c = (UserDefaults.standard.dictionary(forKey: catKey) as? [String: String]) ?? [:]
        catCache = c; return c
    }
    private static func blDict() -> [String: String] {
        memoLock.lock(); defer { memoLock.unlock() }
        if let c = blCache { return c }
        let c = (UserDefaults.standard.dictionary(forKey: blSubKey) as? [String: String]) ?? [:]
        blCache = c; return c
    }
    static func invalidateCaches() {
        memoLock.lock(); catCache = nil; blCache = nil; autoMemo = [:]; memoLock.unlock()
    }
    static func categoryOverride(_ id: String) -> Category? {
        catDict()[id].flatMap(Category.init(rawValue:))
    }
    @MainActor static func setCategory(_ ids: [String], _ c: Category?) {
        var d = (UserDefaults.standard.dictionary(forKey: catKey) as? [String: String]) ?? [:]
        for id in ids { d[id] = c?.rawValue }
        UserDefaults.standard.set(d, forKey: catKey)
        invalidateCaches()
        NotificationCenter.default.post(name: .categoryChanged, object: nil)
    }
    @MainActor static func setCategory(_ id: String, _ c: Category?) {
        var d = (UserDefaults.standard.dictionary(forKey: catKey) as? [String: String]) ?? [:]
        d[id] = c?.rawValue
        UserDefaults.standard.set(d, forKey: catKey)
        invalidateCaches()
        NotificationCenter.default.post(name: .categoryChanged, object: nil)
    }
    /// BL 子分类：电影 / 电视剧 / 短剧 / 动画 / 综艺
    // MARK: region sub-tabs

    enum Region { case cn, hk, tw, jp, kr, th, west, sea, other }
    private static let westCodes: Set<String> = ["US", "GB", "CA", "AU", "NZ", "IE", "FR", "DE", "IT", "ES", "PT", "NL", "BE", "LU", "CH", "AT",
        "SE", "NO", "DK", "FI", "IS", "PL", "CZ", "SK", "HU", "RO", "BG", "GR", "HR", "SI", "RS", "UA", "RU", "EE", "LV", "LT", "MT", "CY", "BY"]
    private static let seaCodes: Set<String> = ["TH", "VN", "PH", "MY", "SG", "ID", "MM", "KH", "LA", "BN", "TL"]
    private static func region(code c: String) -> Region? {
        switch c {
        case "CN": return .cn
        case "HK", "MO": return .hk
        case "TW": return .tw
        case "JP": return .jp
        case "KR": return .kr
        case "TH": return .th
        default: return westCodes.contains(c) ? .west : seaCodes.contains(c) ? .sea : nil
        }
    }
    static func region(_ i: LibraryItem) -> Region {
        if let c = i.regions?.first { return region(code: c) ?? .other }
        switch i.lang ?? "" {
        case "zh", "cn": return .cn
        case "yue": return .hk
        case "ja": return .jp
        case "ko": return .kr
        case "en", "fr", "de", "it", "es", "pt", "nl", "sv", "no", "da", "fi", "pl", "ru": return .west
        case "th": return .th
        case "vi", "id", "ms", "tl": return .sea
        default: return .other
        }
    }
    /// Sub-tabs for a category grid, by its title.
    static func regionTabs(_ title: String) -> [(String, Set<Region>)]? {
        switch title {
        case "电影":
            return [("华语电影", [.cn, .hk, .tw]), ("日韩电影", [.jp, .kr]), ("欧美电影", [.west]), ("东南亚电影", [.th, .sea]), ("其他", [.other])]
        case "动画电影":
            return [("华语电影", [.cn, .hk, .tw]), ("日韩电影", [.jp, .kr]), ("欧美电影", [.west]), ("其他", [.th, .sea, .other])]
        case "电视剧":
            return [("大陆剧", [.cn]), ("港剧", [.hk]), ("台剧", [.tw]), ("韩剧", [.kr]), ("日剧", [.jp]),
                    ("欧美剧", [.west]), ("东南亚剧", [.th, .sea]), ("其他", [.other])]
        case "动画":
            return [("华语动漫", [.cn, .hk, .tw]), ("日韩动漫", [.jp, .kr]), ("欧美动漫", [.west]), ("其他动漫", [.th, .sea, .other])]
        case "综艺":
            return [("大陆综艺", [.cn]), ("港台综艺", [.hk, .tw]), ("韩国综艺", [.kr]), ("日本综艺", [.jp]),
                    ("欧美综艺", [.west]), ("东南亚综艺", [.th, .sea]), ("其他综艺", [.other])]
        case "纪录片":
            return [("华语纪录片", [.cn, .hk, .tw]), ("日韩纪录片", [.jp, .kr]), ("欧美纪录片", [.west]), ("其他纪录片", [.th, .sea, .other])]
        default: return nil
        }
    }

    enum BLSub: String, CaseIterable {
        case movie, tv, short, anime, variety, micro
        var name: String {
            switch self { case .movie: "电影"; case .tv: "电视剧"; case .short: "短剧"; case .anime: "动画"; case .variety: "综艺"; case .micro: "微电影" }
        }
    }
    private static let blSubKey = "lib.blsub"
    static func blSubOverride(_ id: String) -> BLSub? {
        blDict()[id].flatMap(BLSub.init(rawValue:))
    }
    static func autoBLSub(_ i: LibraryItem) -> BLSub {
        // 微电影: tagged in title/folder or by Douban/TMDB genre "短片".
        let hay = i.title + (i.originalTitle ?? "") + (i.files.first?.file.path ?? "")
        if !i.isTV, hay.contains("微电影") || (i.dbGenres ?? []).contains("短片") || (i.genres ?? []).contains("短片") { return .micro }
        switch autoCategory(i, ignoreBL: true) {
        case .shortDrama: return .short
        case .anime, .animeMovie: return .anime
        case .variety: return .variety
        case .tv: return .tv
        case .doc: return i.isTV ? .tv : .movie
        default: return i.isTV ? .tv : .movie
        }
    }
    static func blSub(_ i: LibraryItem) -> BLSub { blSubOverride(i.id) ?? autoBLSub(i) }
    @MainActor static func setBLSub(_ ids: [String], _ c: BLSub?) {
        var d = (UserDefaults.standard.dictionary(forKey: blSubKey) as? [String: String]) ?? [:]
        for id in ids { d[id] = c?.rawValue }
        UserDefaults.standard.set(d, forKey: blSubKey)
        // moving into a BL sub-category also puts the item in BL
        if c != nil {
            var cd = (UserDefaults.standard.dictionary(forKey: catKey) as? [String: String]) ?? [:]
            for id in ids { cd[id] = Category.bl.rawValue }
            UserDefaults.standard.set(cd, forKey: catKey)
        }
        invalidateCaches()
        NotificationCenter.default.post(name: .categoryChanged, object: nil)
    }

    static func autoCategory(_ i: LibraryItem, ignoreBL: Bool = false) -> Category {
        // Regex-heavy, so memoise per item; the signature changes whenever the inputs do.
        let sig = "\(ignoreBL)|\(i.title)|\(i.originalTitle ?? "")|\(i.tmdbId ?? 0)|\(i.kind)|\(i.keywords?.count ?? -1)|\(i.genres?.joined() ?? "")|\(i.files.count)|\(i.files.first?.id ?? "")|\(i.dbGenres?.joined() ?? "-")"
        let key = (ignoreBL ? "b:" : "a:") + i.id
        memoLock.lock(); let hit = autoMemo[key]; memoLock.unlock()
        if let hit, hit.0 == sig { return hit.1 }
        let c = autoCategoryUncached(i, ignoreBL: ignoreBL)
        memoLock.lock(); autoMemo[key] = (sig, c); memoLock.unlock()
        return c
    }
    private static func autoCategoryUncached(_ i: LibraryItem, ignoreBL: Bool) -> Category {
        if !ignoreBL && autoBL(i) { return .bl }
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
        "gay relationship", "gay lead character", "gay theme", "gay kiss", "male homosexuality", "homosexual relationship",
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
        let kw = i.keywords ?? []
        if kw.contains(where: { blKeywords.contains($0) || $0.contains("boys' love") || $0.contains("boys’ love") || $0.contains("yaoi") }) { return true }
        // Douban genre 「同性」, unless TMDB says it's only girls' love
        if i.dbGenres?.contains("同性") == true {
            let gl = kw.contains { $0.contains("girls' love") || $0 == "lesbian" || $0 == "lesbian relationship" || $0.contains("yuri") }
            if !gl { return true }
        }
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
            let xs = items.filter { f($0.shownRating ?? 0) }
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
        h.nOther = items.count - h.nMovies - h.nShows   // 纪录片/BL/短剧/演唱会/其他 都算进来，三格加起来 = 影片总数
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
    @State private var barVisible = true

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
                            shelfRow("短剧", shelves.shortDramas)
                            shelfRow("动画", shelves.anime)
                            shelfRow("综艺", shelves.variety)
                            shelfRow("纪录片", shelves.docs)
                            shelfRow("演唱会", shelves.concerts)
                            shelfRow("BL", shelves.bl, route: .bl)
                            shelfRow("其他", shelves.other)
                            bucketRow("类型", shelves.genres)
                            stats
                        }
                        .padding(.bottom, 120)
                    }
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea(edges: .top)
                    .refreshable { await library.scan() }
                    // hide the top controls while scrolling down, bring them back on any upward scroll (or at the top)
                    .onScrollGeometryChange(for: CGFloat.self) { g in g.contentOffset.y + g.contentInsets.top } action: { old, y in
                        let show: Bool
                        if y < 40 { show = true }
                        else if y - old > 6 { show = false }
                        else if old - y > 6 { show = true }
                        else { return }
                        if show != barVisible { withAnimation(.easeInOut(duration: 0.2)) { barVisible = show } }
                    }
                }
                topBar
                    .opacity(barVisible ? 1 : 0)
                    .offset(y: barVisible ? 0 : -24)
                    .allowsHitTesting(barVisible)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: LibraryItem.self) { DetailView(itemId: $0.id) }
            .navigationDestination(for: ShelfRoute.self) { r in
                switch r {
                case .items(let t, let ids): ItemGridView(title: t, ids: ids, groupCollections: t == "电影" || t == "动画电影")
                case .collection(let t, let ids): ItemGridView(title: t, ids: ids, sortByYear: true)
                case .buckets(let t, let b): BucketListView(title: t, buckets: b)
                case .bl: ItemGridView(title: "BL", ids: [], bl: true)
                }
            }
            .sheet(isPresented: $showFolders) { LibraryFoldersView() }
            .onReceive(NotificationCenter.default.publisher(for: .resumeChanged).throttle(for: .seconds(3), scheduler: RunLoop.main, latest: true)) { _ in resumeTick += 1; rebuild() }
            .onReceive(library.$items.debounce(for: .seconds(1.5), scheduler: RunLoop.main)) { _ in rebuild() }
            .onReceive(NotificationCenter.default.publisher(for: .categoryChanged)) { _ in rebuild() }
            .onReceive(marks.objectWillChange.debounce(for: .seconds(0.3), scheduler: RunLoop.main)) { _ in rebuild() }
            .onAppear { rebuild() }
            .task { await library.enrich() }
        }
    }


    // MARK: top bar

    private var topBar: some View {
        HStack {
            if library.scanning || library.dirScan != nil || library.enrichLeft > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").foregroundStyle(.green)
                    Text(library.scanning ? "数据同步中" : library.dirScan ?? "补全分类 剩余 \(library.enrichLeft)").font(.subheadline.weight(.medium)).monospacedDigit()
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
        if let r = library.lastResult, !library.scanning, library.dirScan == nil, r.hasPrefix("扫描失败") || r.contains("没在") || r.hasPrefix("「") {
            Label(r, systemImage: r.hasPrefix("「") ? "checkmark.circle" : "exclamationmark.triangle").font(.footnote).padding(12)
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

    @ViewBuilder private func shelfRow(_ title: String, _ items: [LibraryItem], route: ShelfRoute? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header(title, count: items.count, route: route ?? .items(title, items.map(\.id)))
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
            Text("共 \(library.items.count) 部影片 · \(library.items.reduce(0) { $0 + $1.files.count }) 个视频文件")
                .font(.footnote).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
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
        router.play(PlayRequest(source: src, file: f.file, siblings: [], title: t, extraSubtitles: f.subtitles, itemId: item.id, fileId: f.id))
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
                if let o = (MetaSource.douban && it.dbIntro?.isEmpty == false ? it.dbIntro : d?.overview?.isEmpty == false ? d?.overview : it.overview), !o.isEmpty {
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
            if let r = it.shownRating, r > 0 {
                HStack(spacing: 2) { Image(systemName: "star.fill").foregroundStyle(.yellow); Text(String(format: "%.1f", r)) }
            }
            ForEach(Array(ps.enumerated()), id: \.offset) { i, p in
                if i > 0 || (it.shownRating ?? 0) > 0 { Text("|").foregroundStyle(.white.opacity(0.5)) }
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

struct BLSubMenuItems: View {
    let item: LibraryItem
    var body: some View {
        let cur = Groupings.blSub(item)
        Section("BL 子分类（当前：\(cur.name)）") {
            ForEach(Groupings.BLSub.allCases, id: \.self) { c in
                Button { Groupings.setBLSub([item.id], c) } label: {
                    if c == cur { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
        }
    }
}

extension View {
    func categoryMenu(_ item: LibraryItem) -> some View {
        contextMenu {
            if Groupings.isBL(item) { BLSubMenuItems(item: item) }
            CategoryMenuItems(item: item, flat: true)
        }
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
                    if let r = item.shownRating, r > 0 {
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
    var bl = false
    var groupCollections = false
    var sortByYear = false
    @EnvironmentObject var library: LibraryStore
    @AppStorage("grid.sort") private var sort = 0          // 0 添加时间 1 名称 2 评分 3 年份 (shared by every category)
    @AppStorage("grid.sortAsc") private var asc = false
    @State private var blTab: Groupings.BLSub? = nil
    @State private var regionTab: String? = nil
    @State private var tick = 0
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var toast: String?

    private var items: [LibraryItem] {
        let _ = tick
        let xs: [LibraryItem]
        if bl {
            let all = library.items.filter(Groupings.isBL).sorted { $0.added > $1.added }
            xs = blTab.map { t in all.filter { Groupings.blSub($0) == t } } ?? all
        } else {
            let byId = Dictionary(library.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let base = ids.compactMap { byId[$0] }
            if let t = regionTab, let set = Groupings.regionTabs(title)?.first(where: { $0.0 == t })?.1 {
                xs = base.filter { set.contains(Groupings.region($0)) }
            } else { xs = base }
        }
        if sortByYear && sort == 0 { return xs.sorted { ($0.year ?? 9999, $0.title) < ($1.year ?? 9999, $1.title) } }
        let a = asc
        switch sort {
        case 1: return xs.sorted { let r = $0.title.localizedStandardCompare($1.title); return a ? r == .orderedAscending : r == .orderedDescending }
        case 2: return xs.sorted { a ? ($0.shownRating ?? 0, $0.title) < ($1.shownRating ?? 0, $1.title) : ($0.shownRating ?? 0, $1.title) > ($1.shownRating ?? 0, $0.title) }
        case 3: return xs.sorted { a ? ($0.year ?? 9999, $0.title) < ($1.year ?? 9999, $1.title) : ($0.year ?? 0, $1.title) > ($1.year ?? 0, $0.title) }
        default: return xs.sorted { a ? $0.added < $1.added : $0.added > $1.added }
        }
    }

    private enum Entry: Identifiable {
        case item(LibraryItem)
        case col(Int, String, URL?, [LibraryItem])
        var id: String { switch self { case .item(let i): return i.id; case .col(let c, _, _, _): return "col-\(c)" } }
    }

    /// Movies sharing a TMDB collection (2+ in this grid) fold into one tile at the first member's position.
    private var entries: [Entry] {
        let xs = items
        guard groupCollections, !selecting else { return xs.map { .item($0) } }
        var members: [Int: [LibraryItem]] = [:]
        for it in xs where !it.isTV { if let c = it.collectionId { members[c, default: []].append(it) } }
        var out: [Entry] = []; var done = Set<Int>()
        for it in xs {
            if !it.isTV, let c = it.collectionId, let m = members[c], m.count >= 2 {
                if done.insert(c).inserted {
                    let sorted = m.sorted { ($0.year ?? 9999) < ($1.year ?? 9999) }
                    out.append(.col(c, it.collectionName ?? it.title, it.collectionPoster ?? sorted.first?.poster, sorted))
                }
            } else { out.append(.item(it)) }
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HomeStyle.bg.ignoresSafeArea()
            ScrollView {
                if bl { blTabs } else if Groupings.regionTabs(title) != nil { regionTabs }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)], spacing: 18) {
                    ForEach(entries) { e in
                      switch e {
                      case .col(_, let name, let poster, let ms):
                        NavigationLink(value: ShelfRoute.collection(name, ms.map(\.id))) {
                            CollectionTile(name: name, poster: poster, count: ms.count, width: 104)
                        }.buttonStyle(.plain)
                      case .item(let it):
                        if selecting {
                            Button { toggle(it.id) } label: {
                                PosterTile(item: it, width: 104)
                                    .opacity(selected.contains(it.id) ? 1 : 0.55)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: selected.contains(it.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2).symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, selected.contains(it.id) ? Color.pink : Color.black.opacity(0.35))
                                            .padding(6)
                                    }
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink(value: it) { PosterTile(item: it, width: 104) }.buttonStyle(.plain)
                                .contextMenu {
                                    Button { selecting = true; selected = [it.id] } label: { Label("多选", systemImage: "checkmark.circle") }
                                    if bl { BLSubMenuItems(item: it) }
                                    CategoryMenuItems(item: it, flat: true)
                                }
                        }
                      }
                    }
                }
                .padding(16)
                .padding(.bottom, 120)
            }
            if selecting { selectionBar }
            if let t = toast {
                Text(t).font(.footnote.weight(.semibold)).padding(.horizontal, 16).frame(height: 40)
                    .glass(in: Capsule()).padding(.bottom, selecting ? 100 : 40)
                    .task(id: t) { try? await Task.sleep(nanoseconds: 1_800_000_000); withAnimation { toast = nil } }
            }
        }
        .navigationTitle(selecting ? "已选 \(selected.count) 部" : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if selecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selected.count == items.count ? "全不选" : "全选") {
                        selected = selected.count == items.count ? [] : Set(items.map(\.id))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { selecting = false; selected = [] }.bold()
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("选择") { selecting = true; selected = [] }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        sortButton(0, "添加时间", "最早在前", "最新在前")
                        sortButton(1, "名称", "A→Z", "Z→A")
                        sortButton(2, "评分", "低→高", "高→低")
                        sortButton(3, "年份", "从旧到新", "从新到旧")
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuActionDismissBehavior(.disabled)
                }
            }
        }
        .navigationBarBackButtonHidden(selecting)
        .foregroundStyle(.white)
        .onReceive(NotificationCenter.default.publisher(for: .categoryChanged)) { _ in tick += 1 }
    }

    /// Tap a sort once = ascending (年份 从旧到新); tap it again = descending, and so on.
    private func sortButton(_ tag: Int, _ name: String, _ up: String, _ down: String) -> some View {
        Button {
            if sort == tag { asc.toggle() } else { sort = tag; asc = true }
        } label: {
            if sort == tag {
                Label("\(name)（\(asc ? up : down)）", systemImage: asc ? "arrow.up" : "arrow.down")
            } else {
                Text(name)
            }
        }
    }

    private var blTabs: some View {
        let all = library.items.filter(Groupings.isBL)
        let counts = Dictionary(grouping: all, by: Groupings.blSub).mapValues(\.count)
        let tabs: [(Groupings.BLSub?, String, Int)] = [(nil, "全部", all.count)] + Groupings.BLSub.allCases.map { ($0, $0.name, counts[$0] ?? 0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs, id: \.1) { t in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { blTab = t.0; selected = [] } } label: {
                        Text("\(t.1) \(t.2)").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 36)
                            .foregroundStyle(blTab == t.0 ? Color.black : Color.white)
                            .background(blTab == t.0 ? Color.white : HomeStyle.card, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private var regionTabs: some View {
        let byId = Dictionary(library.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let base = ids.compactMap { byId[$0] }
        let regs = base.map(Groupings.region)
        let defs = Groupings.regionTabs(title) ?? []
        let tabs: [(String?, String, Int)] = [(nil, "全部", base.count)] + defs.map { d in (d.0, d.0, regs.filter { d.1.contains($0) }.count) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs, id: \.1) { t in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { regionTab = t.0; selected = [] } } label: {
                        Text("\(t.1) \(t.2)").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 36)
                            .foregroundStyle(regionTab == t.0 ? Color.black : Color.white)
                            .background(regionTab == t.0 ? Color.white : HomeStyle.card, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private var selectionBar: some View {
        Menu {
            if bl {
                Section("BL 子分类") {
                    ForEach(Groupings.BLSub.allCases, id: \.self) { c in
                        Button("BL · " + c.name) { moveSub(c) }
                    }
                    Button { moveSub(nil) } label: { Label("BL 子分类改回自动", systemImage: "arrow.uturn.backward") }
                }
            }
            ForEach(Groupings.Category.allCases, id: \.self) { c in
                Button(c.name) { move(to: c) }
            }
            Divider()
            Button { move(to: nil) } label: { Label("恢复自动分类", systemImage: "arrow.uturn.backward") }
        } label: {
            Label(selected.isEmpty ? "先选择影片" : "移到分类（\(selected.count) 部）", systemImage: "folder.badge.gearshape")
                .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
        }
        .disabled(selected.isEmpty)
        .glass(in: Capsule(), interactive: true)
        .padding(.horizontal, 24).padding(.bottom, 30)
    }

    private func moveSub(_ c: Groupings.BLSub?) {
        let ids = Array(selected)
        Groupings.setBLSub(ids, c)
        toast = c.map { "已把 \(ids.count) 部移到「BL · \($0.name)」" } ?? "已恢复 \(ids.count) 部的自动子分类"
        selected = []
        selecting = false
    }

    private func move(to c: Groupings.Category?) {
        let ids = Array(selected)
        Groupings.setCategory(ids, c)
        toast = c.map { "已把 \(ids.count) 部移到「\($0.name)」" } ?? "已恢复 \(ids.count) 部的自动分类"
        selected = []
        selecting = false
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
    @AppStorage("search.history") private var historyRaw = ""
    @State private var picks: [String] = []          // 推荐观看 item ids

    private var history: [String] { historyRaw.isEmpty ? [] : historyRaw.components(separatedBy: "\n") }
    private func remember(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var h = history.filter { $0 != t }
        h.insert(t, at: 0)
        historyRaw = h.prefix(20).joined(separator: "\n")
    }
    private func shuffle() {
        let pool = library.items.filter { $0.poster != nil }
        let rated = pool.filter { ($0.shownRating ?? 0) >= 6.5 }
        let src = rated.count >= 9 ? rated : pool
        picks = Array(src.shuffled().prefix(9)).map(\.id)
    }

    private var results: [LibraryItem] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        return library.items.filter {
            $0.title.localizedCaseInsensitiveContains(t) || ($0.originalTitle ?? "").localizedCaseInsensitiveContains(t)
                || ($0.genres ?? []).contains { $0.localizedCaseInsensitiveContains(t) }
                || $0.files.contains { $0.file.name.localizedCaseInsensitiveContains(t) }
        }
    }

    private var tileWidth: CGFloat { max(90, (UIScreen.main.bounds.width - 32 - 24) / 3) }

    var body: some View {
        NavigationStack {
            ZStack {
                HomeStyle.bg.ignoresSafeArea()
                ScrollView {
                    if q.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            if !history.isEmpty {
                                HStack {
                                    Text("历史记录").font(.title3.bold())
                                    Spacer()
                                    Button { historyRaw = "" } label: { Image(systemName: "trash").font(.title3) }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                ChipFlow(spacing: 10) {
                                    ForEach(history, id: \.self) { h in
                                        Button { q = h; remember(h) } label: {
                                            Text(h).font(.subheadline).lineLimit(1)
                                                .padding(.horizontal, 16).frame(height: 38)
                                                .background(HomeStyle.card, in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                            let items = picks.compactMap { id in library.items.first { $0.id == id } }
                            if !items.isEmpty {
                                HStack {
                                    Text("推荐观看").font(.title3.bold())
                                    Spacer()
                                    Button { withAnimation { shuffle() } } label: {
                                        HStack(spacing: 4) { Text("换一批"); Image(systemName: "arrow.clockwise") }.font(.subheadline)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 18) {
                                    ForEach(items) { it in
                                        NavigationLink(value: it) { PosterTile(item: it, width: tileWidth) }.buttonStyle(.plain).categoryMenu(it)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: q).padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)], spacing: 18) {
                            ForEach(results) { it in
                                NavigationLink(value: it) { PosterTile(item: it, width: 104) }.buttonStyle(.plain).categoryMenu(it)
                                    .simultaneousGesture(TapGesture().onEnded { remember(q) })
                            }
                        }
                        .padding(16)
                    }
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("搜索")
            .searchable(text: $q, prompt: "影片、剧集、类型、文件名")
            .onSubmit(of: .search) { remember(q) }
            .onAppear { if picks.isEmpty { shuffle() } }
            .onChange(of: library.items.count) { _, _ in if picks.isEmpty { shuffle() } }
            .navigationDestination(for: LibraryItem.self) { DetailView(itemId: $0.id) }
            .navigationDestination(for: ShelfRoute.self) { r in
                switch r {
                case .items(let t, let ids): ItemGridView(title: t, ids: ids, groupCollections: t == "电影" || t == "动画电影")
                case .collection(let t, let ids): ItemGridView(title: t, ids: ids, sortByYear: true)
                case .buckets(let t, let b): BucketListView(title: t, buckets: b)
                case .bl: ItemGridView(title: "BL", ids: [], bl: true)
                }
            }
        }
    }
}

/// Wrapping row of chips sized to their own text (搜索历史).
struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.init(width: maxW, height: nil))
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .init(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
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


/// A TMDB movie collection shown as one stacked poster in the 电影 grid.
struct CollectionTile: View {
    let name: String
    let poster: URL?
    let count: Int
    var width: CGFloat = 104
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.12))
                    .frame(width: width - 16, height: width * 1.5).offset(y: -8)
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.2))
                    .frame(width: width - 8, height: width * 1.5).offset(y: -4)
                PosterImage(url: poster, title: name)
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(count)").font(.caption.weight(.heavy).monospacedDigit()).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(height: 22).background(Capsule().fill(.black.opacity(0.55))).padding(6)
                    }
            }
            .padding(.top, 8)
            Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(count) 部电影").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}
