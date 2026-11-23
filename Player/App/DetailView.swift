import SwiftUI
import UIKit
import CoreImage

// MARK: - Local marks (favorite / watchlist / watched)

final class ItemMarks: ObservableObject {
    static let shared = ItemMarks()
    private let d = UserDefaults.standard
    @Published var favorites: Set<String> { didSet { d.set(Array(favorites), forKey: "marks.fav") } }
    @Published var watchlist: Set<String> { didSet { d.set(Array(watchlist), forKey: "marks.list") } }
    @Published var watched: Set<String> { didSet { d.set(Array(watched), forKey: "marks.watched") } }
    private init() {
        favorites = Set(d.stringArray(forKey: "marks.fav") ?? [])
        watchlist = Set(d.stringArray(forKey: "marks.list") ?? [])
        watched = Set(d.stringArray(forKey: "marks.watched") ?? [])
    }
    func toggle(_ set: ReferenceWritableKeyPath<ItemMarks, Set<String>>, _ id: String) {
        if self[keyPath: set].contains(id) { self[keyPath: set].remove(id) } else { self[keyPath: set].insert(id) }
    }
}

// MARK: - Poster tone (average color for the blended background)

@MainActor
final class PosterTone: ObservableObject {
    @Published var color: Color = Color(white: 0.16)
    @Published var isLight = false
    @Published var image: UIImage?
    private var loaded: URL?
    private static let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    func load(_ url: URL?) async {
        guard let url, url != loaded else { return }
        loaded = url
        guard let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) else { return }
        image = img
        // average of the bottom third, which is what the background continues from
        guard let ci = CIImage(image: img) else { return }
        let e = ci.extent
        let region = CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height / 3)
        guard let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: region)]),
              let out = f.outputImage else { return }
        var px = [UInt8](repeating: 0, count: 4)
        Self.ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        // mute it so text stays readable
        var r = Double(px[0]) / 255, g = Double(px[1]) / 255, b = Double(px[2]) / 255
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        let k = 0.55
        r = r * k + lum * (1 - k); g = g * k + lum * (1 - k); b = b * k + lum * (1 - k)
        let dim = 0.62
        r *= dim; g *= dim; b *= dim
        withAnimation(.easeOut(duration: 0.4)) { color = Color(red: r, green: g, blue: b); isLight = false }
    }
}

// MARK: - Detail page

struct DetailView: View {
    let itemId: String
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var sources: SourceStore
    @EnvironmentObject var router: PlaybackRouter
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var marks = ItemMarks.shared
    @StateObject private var tone = PosterTone()
    @State private var season: Int?
    @State private var pickedEp: String?
    @State private var epOverview: [String: String] = [:]
    @State private var details: TMDBDetails?
    @State private var expanded = false
    @State private var showAllEpisodes = false
    @State private var showEdit = false
    @State private var barsVisible = true
    @State private var confirmRemove = false
    @State private var openRelated: LibraryItem?
    @ObservedObject private var dl = DownloadStore.shared

    private var item: LibraryItem? { library.items.first { $0.id == itemId } }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                tone.color.ignoresSafeArea()
                if let item {
                    ScrollView {
                        VStack(spacing: 0) {
                            hero(item, width: geo.size.width, height: max(520, geo.size.height * 0.72))
                            VStack(alignment: .leading, spacing: 26) {
                                actionRow(item)
                                overview(item)
                                if item.isTV { episodes(item)
                                    episodeInfo(item) } else if item.files.count > 1 { versions(item) }
                                if let f = firstPlayable(item) { MediaInfoCards(file: f) }
                                cast
                                genres
                                recent(item)
                                locations(item)
                            }
                            .padding(.top, 18)
                            .padding(.bottom, 50)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea(edges: .top)
                    .onScrollGeometryChange(for: Bool.self) { g in
                        g.contentOffset.y + g.contentInsets.top < 30
                    } action: { _, atTop in
                        if atTop != barsVisible { withAnimation(.easeInOut(duration: 0.2)) { barsVisible = atTop } }
                    }
                    topBar(item)
                        .opacity(barsVisible ? 1 : 0)
                        .offset(y: barsVisible ? 0 : -20)
                        .allowsHitTesting(barsVisible)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .foregroundStyle(.white)
        .task(id: itemId) {
            if season == nil { season = item?.seasons.first }
            guard let item else { return }
            let poster = item.poster
            Task { await tone.load(poster) }
            if let id = item.tmdbId {
                let d = await TMDB.details(id: id, tv: item.isTV)
                withAnimation { details = d }
                if let hi = d?.posterHi, hi != item.poster { await tone.load(hi) }
            }
        }
        .sheet(isPresented: $showEdit) { if let item { EditInfoView(item: item) } }
        .confirmationDialog("从媒体库中移除？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移除", role: .destructive) { library.removeItem(itemId); dismiss() }
        } message: { Text("网盘里的文件不会被删除，可在 设置 › 媒体库 里恢复。") }
        .overlay(alignment: .bottom) { downloadBadge }
        .navigationDestination(item: $openRelated) { DetailView(itemId: $0.id) }
        .sheet(isPresented: $showAllEpisodes) {
            if let item { AllEpisodesSheet(item: item, season: $season, play: { play($0, item) }) }
        }
    }

    // MARK: hero

    private func hero(_ item: LibraryItem, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if let img = tone.image {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    PosterImage(url: item.poster, title: "")
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .overlay(
                LinearGradient(stops: [.init(color: .clear, location: 0.0), .init(color: .clear, location: 0.45),
                                       .init(color: tone.color.opacity(0.75), location: 0.75), .init(color: tone.color, location: 1.0)],
                               startPoint: .top, endPoint: .bottom)
            )

            VStack(spacing: 10) {
                if let logo = details?.logo {
                    AsyncImage(url: logo) { ph in
                        if let i = ph.image { i.resizable().scaledToFit() } else { titleText(item) }
                    }
                    .frame(maxWidth: width * 0.62, maxHeight: 120)
                    .shadow(color: .black.opacity(0.35), radius: 6)
                } else {
                    titleText(item)
                }
                metaLine(item)
                if let sub = countLine(item) {
                    Text(sub).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                }
                if let f = firstPlayable(item) {
                    Button { play(f, item) } label: {
                        Label(resumeLabel(item, f), systemImage: "play.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 58)
                            .background(.white.opacity(0.92), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 30).padding(.top, 8)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(width: width, height: height)
    }

    private func titleText(_ item: LibraryItem) -> some View {
        Text(details?.title.isEmpty == false ? details!.title : item.title)
            .font(.system(size: 34, weight: .heavy))
            .multilineTextAlignment(.center).lineLimit(2)
            .padding(.horizontal, 24)
            .shadow(color: .black.opacity(0.5), radius: 6)
    }

    private func metaLine(_ item: LibraryItem) -> some View {
        var parts: [String] = []
        if let d = details?.date { parts.append(d) } else if let y = item.year { parts.append(String(y)) }
        if let c = details?.countries, !c.isEmpty { parts.append(c.joined(separator: ",")) }
        if let g = details?.genres, !g.isEmpty { parts.append(g.prefix(2).joined(separator: ",")) }
        if !item.isTV, let rt = details?.runtime, rt > 0 { parts.append("\(rt / 60 > 0 ? "\(rt / 60)小时" : "")\(rt % 60)分钟") }
        let rating = details?.rating ?? item.rating
        let ps = parts
        return HStack(spacing: 8) {
            if let r = rating, r > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(String(format: "%.1f", r))
                }
            }
            ForEach(Array(ps.enumerated()), id: \.offset) { i, p in
                if i > 0 || (rating ?? 0) > 0 { Text("|").foregroundStyle(.white.opacity(0.5)) }
                Text(p)
            }
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1).minimumScaleFactor(0.7)
        .padding(.horizontal, 20)
        .shadow(color: .black.opacity(0.4), radius: 3)
    }

    private func countLine(_ item: LibraryItem) -> String? {
        guard item.isTV else { return nil }
        let found = item.files.count
        if let total = details?.totalEpisodes, total > 0 {
            return total == found ? "共\(total)集" : "共\(total)集（找到\(found)集）"
        }
        return "找到\(found)集"
    }

    // MARK: actions

    private func actionRow(_ item: LibraryItem) -> some View {
        HStack(spacing: 70) {
            markButton(item, \.favorites, on: "heart.fill", off: "heart")
            markButton(item, \.watchlist, on: "text.badge.checkmark", off: "text.badge.plus")
            markButton(item, \.watched, on: "flag.fill", off: "flag")
        }
        .font(.system(size: 26))
        .frame(maxWidth: .infinity)
    }

    private func markButton(_ item: LibraryItem, _ kp: ReferenceWritableKeyPath<ItemMarks, Set<String>>, on: String, off: String) -> some View {
        let active = marks[keyPath: kp].contains(item.id)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            marks.toggle(kp, item.id)
        } label: {
            Image(systemName: active ? on : off).foregroundStyle(active ? Color.pink : .white)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    private func overview(_ item: LibraryItem) -> some View {
        let text = (details?.overview?.isEmpty == false ? details?.overview : item.overview) ?? ""
        let head: String = {
            var t = "「\(item.title)"
            if item.isTV, let s = season ?? item.seasons.first { t += " · 第\(s)季" }
            return t + "」"
        }()
        return VStack(spacing: 12) {
            if !text.isEmpty {
                (Text(head).bold() + Text(text))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(expanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { withAnimation(.easeInOut) { expanded.toggle() } }
            }
            if let vc = details?.voteCount, vc > 0, let r = details?.rating, r > 0 {
                HStack(spacing: 6) {
                    Text("TMDB").font(.caption2.weight(.black)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(red: 0.0, green: 0.82, blue: 0.67), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.black)
                    Text(String(format: "%.1f", r)).font(.subheadline)
                    Text("· \(vc) 人评分").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: episodes

    private func episodes(_ item: LibraryItem) -> some View {
        let s = season ?? item.seasons.first
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    ForEach(item.seasons, id: \.self) { n in
                        Button { season = n } label: { if n == s { Label("第\(n)季", systemImage: "checkmark") } else { Text("第\(n)季") } }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("第\(s ?? 1)季").font(.title2.bold())
                        Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                }
                Spacer()
                Button { showAllEpisodes = true } label: {
                    HStack(spacing: 4) { Text("查看全部"); Image(systemName: "chevron.right") }
                        .font(.headline).foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(item.episodes(season: s)) { ep in
                        Button {
                            // first tap picks the episode (文件位置 shows it), second tap plays
                            // tap shows this episode's info + file location; play from the info card or the top button
                            withAnimation(.easeInOut(duration: 0.15)) { pickedEp = ep.id }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                PosterImage(url: ep.still ?? item.backdrop, title: "")
                                    .frame(width: 232, height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay {
                                        if pickedEp == ep.id {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white, lineWidth: 3)
                                            }
                                        }
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        if marks.watched.contains(ep.id) {
                                            Image(systemName: "checkmark.circle.fill").padding(8)
                                        }
                                    }
                                Text(epTitle(ep)).font(.subheadline.weight(.medium)).lineLimit(1)
                                    .frame(width: 232, alignment: .leading)
                            }
                            .frame(width: 232)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(marks.watched.contains(ep.id) ? "标为未看" : "标为已看") { marks.toggle(\.watched, ep.id) }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder private func episodeInfo(_ item: LibraryItem) -> some View {
        if let p = pickedEp, let ep = item.files.first(where: { $0.id == p }) {
            let g = locGroups(item).first
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("第\(ep.season ?? 1)季 · " + epTitle(ep)).font(.headline).lineLimit(2)
                    Spacer()
                    Button { withAnimation { pickedEp = nil } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
                        .buttonStyle(.plain)
                }
                if let o = epOverview[ep.id], !o.isEmpty {
                    Text(o).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                }
                if let g {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(g.drive, systemImage: "externaldrive.connected.to.line.below").font(.caption.weight(.semibold))
                        if !g.path.isEmpty { Text(g.path).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled) }
                        Text(ep.file.name + (ep.file.sizeText.isEmpty ? "" : " · " + ep.file.sizeText))
                            .font(.caption).foregroundStyle(.white.opacity(0.65)).textSelection(.enabled)
                    }
                    .contextMenu {
                        Button { UIPasteboard.general.string = g.drive + "\n" + g.path + "/" + ep.file.name } label: { Label("复制路径", systemImage: "doc.on.doc") }
                    }
                }
            }
            .padding(14)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)
            .task(id: ep.id) {
                guard epOverview[ep.id] == nil, let tv = item.tmdbId, let s = ep.season, let e = ep.episode else { return }
                let eps = await TMDB.season(tvId: tv, season: s)
                epOverview[ep.id] = eps[e]?.overview ?? ""
            }
        }
    }

    private func epTitle(_ ep: LibraryFile) -> String {
        let n = ep.episode.map { "\($0). " } ?? ""
        if let t = ep.episodeTitle, !t.isEmpty { return n + t }
        return n + (ep.episode.map { "第 \($0) 集" } ?? ep.file.baseName)
    }

    private func versions(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("版本").font(.title2.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(item.files) { f in
                        Button { play(f, item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(f.file.name).font(.footnote.weight(.semibold)).lineLimit(2)
                                Text([sources.source(f.sourceId)?.name ?? "", f.file.sizeText].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(12).frame(width: 220, alignment: .leading)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: file locations

    private struct LocGroup: Identifiable { let id: String; let drive: String; let path: String; let files: [LibraryFile] }

    private func locGroups(_ item: LibraryItem) -> [LocGroup] {
        var order: [String] = []
        var map: [String: (String, String, [LibraryFile])] = [:]
        var files = item.files
        if item.isTV {
            let one = item.files.first { $0.id == pickedEp } ?? firstPlayable(item)
            files = one.map { [$0] } ?? []
        }
        for f in files {
            let src = sources.source(f.sourceId)
            let drive = src.map { $0.name == $0.kind.title || $0.name.isEmpty ? $0.kind.title : "\($0.kind.title) · \($0.name)" } ?? "未知来源"
            var path = f.file.meta["dirPath"] ?? ""
            if path.isEmpty {
                let folder = library.folders.first { $0.id.uuidString == f.file.meta["folder"] }
                if src?.kind == .local || src?.kind == .smb || src?.kind == .webdav {
                    path = (f.file.path as NSString).deletingLastPathComponent
                } else if let folder { path = "/" + folder.title + "/…" }
            }
            let key = f.sourceId.uuidString + "|" + path
            if map[key] == nil { map[key] = (drive, path, []); order.append(key) }
            map[key]!.2.append(f)
        }
        return order.map { LocGroup(id: $0, drive: map[$0]!.0, path: map[$0]!.1, files: map[$0]!.2) }
    }

    @ViewBuilder private func locations(_ item: LibraryItem) -> some View {
        let groups = locGroups(item)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("文件位置").font(.title2.bold())
                    if item.isTV, let f = groups.first?.files.first {
                        Text(epTitle(f)).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .padding(.horizontal, 20)
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(g.drive, systemImage: "externaldrive.connected.to.line.below").font(.subheadline.weight(.semibold))
                        if !g.path.isEmpty {
                            Text(g.path).font(.footnote.monospaced()).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                        }
                        let shown = g.files.sorted { ($0.season ?? 0, $0.episode ?? 0, $0.file.name) < ($1.season ?? 0, $1.episode ?? 0, $1.file.name) }
                        ForEach(shown.prefix(8)) { f in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "film").font(.caption2).padding(.top, 2)
                                Text(f.file.name).font(.caption).lineLimit(3).textSelection(.enabled)
                                Spacer(minLength: 4)
                                Text(f.file.sizeText).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                            }
                            .foregroundStyle(.white.opacity(0.75))
                        }
                        if shown.count > 8 {
                            Text("…等共 \(shown.count) 个文件").font(.caption2).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contextMenu {
                        Button { UIPasteboard.general.string = g.drive + "\n" + g.path } label: { Label("复制路径", systemImage: "doc.on.doc") }
                        Button { UIPasteboard.general.string = g.files.map(\.file.name).joined(separator: "\n") } label: { Label("复制文件名", systemImage: "doc.on.doc") }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: cast / genres / recent

    @ViewBuilder private var cast: some View {
        if let c = details?.cast, !c.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("演职人员").font(.title2.bold()).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(c.enumerated()), id: \.offset) { _, p in
                            VStack(spacing: 6) {
                                AsyncImage(url: p.photo) { ph in
                                    if let i = ph.image { i.resizable().scaledToFill() }
                                    else { ZStack { Color.white.opacity(0.12); Image(systemName: "person.fill").font(.title).foregroundStyle(.white.opacity(0.5)) } }
                                }
                                .frame(width: 92, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                Text(p.name).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                                if !p.role.isEmpty {
                                    Text(p.role).font(.footnote).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                                }
                            }
                            .frame(width: 96)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    @ViewBuilder private var genres: some View {
        if let g = details?.genres, !g.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("风格").font(.title2.bold())
                HStack(spacing: 10) {
                    ForEach(g, id: \.self) { x in
                        Text(x).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// 相关推荐: library items TMDB lists as recommended/similar first, then items sharing the most genres.
    private func related(_ item: LibraryItem) -> [LibraryItem] {
        let others = library.items.filter { $0.id != item.id && $0.tmdbId != nil }
        var out: [LibraryItem] = []
        var used = Set<String>()
        if let ids = details?.related, !ids.isEmpty {
            let byTmdb = Dictionary(others.map { ($0.tmdbId!, $0) }, uniquingKeysWith: { a, _ in a })
            for id in ids { if let it = byTmdb[id], used.insert(it.id).inserted { out.append(it) } }
        }
        let g = Set(details?.genres ?? item.genres ?? [])
        if !g.isEmpty {
            var scored: [(item: LibraryItem, score: Int)] = []
            for it in others where !used.contains(it.id) {
                let shared = Set(it.genres ?? []).intersection(g).count
                guard shared > 0 else { continue }
                var sc = shared * 10
                if it.kind == item.kind { sc += 3 }
                if let a = it.year, let b = item.year, abs(a - b) <= 5 { sc += 1 }
                scored.append((it, sc))
            }
            scored.sort { l, r in
                if l.score != r.score { return l.score > r.score }
                return (l.item.rating ?? 0) > (r.item.rating ?? 0)
            }
            for e in scored { out.append(e.item) }
        }
        return Array(out.prefix(20))
    }

    @ViewBuilder private func recent(_ item: LibraryItem) -> some View {
        let list = related(item)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("相关推荐").font(.title2.bold()).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(list) { it in
                            Button { openRelated = it } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    PosterImage(url: it.poster, title: it.title)
                                        .frame(width: 124, height: 180)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(alignment: .bottomTrailing) {
                                            if let r = it.rating, r > 0 {
                                                Text(String(format: "%.1f", r)).font(.caption.weight(.heavy)).padding(6)
                                                    .shadow(color: .black, radius: 3)
                                            }
                                        }
                                    Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(it.isTV ? "共\(max(1, it.seasons.count))季" : (it.year.map { String($0) } ?? "电影"))
                                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                                }
                                .frame(width: 124)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: top bar

    private func topBar(_ item: LibraryItem) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 52, height: 52)
            }
            .glass(in: Circle(), interactive: true)
            Spacer()
            Menu {
                Button { showEdit = true } label: { Label("编辑信息", systemImage: "square.and.pencil") }
                let targets = downloadTargets(item)
                if !targets.isEmpty && targets.allSatisfy({ dl.isDownloaded($0.id) }) {
                    Button(role: .destructive) { for f in targets { dl.delete(f.id) } } label: { Label("删除下载", systemImage: "trash") }
                } else if targets.contains(where: { dl.progress[$0.id] != nil }) {
                    Button { for f in targets { dl.cancel(f.id) } } label: { Label("取消下载", systemImage: "xmark.circle") }
                } else {
                    Button { dl.enqueue(targets, title: item.title) } label: {
                        Label(item.isTV ? "下载本季（\(targets.count) 集）" : "下载", systemImage: "arrow.down.to.line")
                    }
                }
                CategoryMenuItems(item: item)
                Button { setWatched(item, true) } label: { Label("标记为已观看", systemImage: "flag.fill") }
                Button { setWatched(item, false) } label: { Label("标记为未观看", systemImage: "flag") }
                ShareLink(item: shareText(item)) { Label("分享", systemImage: "square.and.arrow.up") }
                Button { Task { await library.rescanItem(item.id) } } label: { Label("重新扫描文件", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { confirmRemove = true } label: { Label("从媒体库中移除", systemImage: "trash") }
                if !item.isTV && item.files.count > 1 {
                    Section("选择版本播放") {
                        ForEach(item.files) { f in Button(f.file.name) { play(f, item) } }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 52, height: 52)
            }
            .glass(in: Circle(), interactive: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    // MARK: menu helpers

    private func downloadTargets(_ item: LibraryItem) -> [LibraryFile] {
        item.isTV ? item.episodes(season: season ?? item.seasons.first) : Array(item.files.prefix(1))
    }

    private func setWatched(_ item: LibraryItem, _ on: Bool) {
        if on {
            marks.watched.insert(item.id)
            for f in item.files { marks.watched.insert(f.id) }
        } else {
            marks.watched.remove(item.id)
            for f in item.files { marks.watched.remove(f.id); Resume.clear(f.id) }
        }
    }

    private func shareText(_ item: LibraryItem) -> String {
        var s = item.title + (item.year.map { " (\($0))" } ?? "")
        if let id = item.tmdbId { s += "\nhttps://www.themoviedb.org/\(item.isTV ? "tv" : "movie")/\(id)" }
        return s
    }

    @ViewBuilder private var downloadBadge: some View {
        if let item {
            let ids = downloadTargets(item).map(\.id)
            let active = ids.compactMap { dl.progress[$0] }
            if !active.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在下载 \(Int(active.reduce(0, +) / Double(active.count) * 100))%" + (active.count > 1 ? "（剩 \(active.count) 个）" : ""))
                        .font(.footnote.monospacedDigit())
                }
                .padding(.horizontal, 16).frame(height: 40)
                .glass(in: Capsule())
                .padding(.bottom, 24)
            } else if let e = dl.lastError {
                Text(e).font(.footnote).lineLimit(2).padding(12)
                    .glass(in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 24).padding(.horizontal, 16)
                    .onTapGesture { dl.lastError = nil }
            }
        }
    }

    // MARK: play

    private func firstPlayable(_ item: LibraryItem) -> LibraryFile? {
        if item.isTV {
            if let p = pickedEp, let f = item.files.first(where: { $0.id == p }) { return f }
            let eps = item.episodes(season: season ?? item.seasons.first)
            return eps.first { !marks.watched.contains($0.id) } ?? eps.first
        }
        return item.files.first
    }

    private func resumeLabel(_ item: LibraryItem, _ f: LibraryFile) -> String {
        if item.isTV, let e = f.episode, f.id != item.episodes(season: season ?? item.seasons.first).first?.id { return "播放 第\(e)集" }
        return "播放"
    }

    private func play(_ f: LibraryFile, _ item: LibraryItem) {
        guard let src = sources.source(f.sourceId) else { return }
        let t = item.isTV ? "\(item.title) 第\(f.episode ?? 0)集" : item.title
        router.play(PlayRequest(source: src, file: f.file, siblings: [], title: t, extraSubtitles: f.subtitles))
    }
}

struct AllEpisodesSheet: View {
    let item: LibraryItem
    @Binding var season: Int?
    let play: (LibraryFile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if item.seasons.count > 1 {
                    Picker("季", selection: Binding(get: { season ?? item.seasons.first ?? 1 }, set: { season = $0 })) {
                        ForEach(item.seasons, id: \.self) { Text("第\($0)季").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ForEach(item.episodes(season: season ?? item.seasons.first)) { ep in
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { play(ep) }   // let the sheet finish closing first
                    } label: {
                        HStack(spacing: 12) {
                            PosterImage(url: ep.still ?? item.backdrop, title: "")
                                .frame(width: 128, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ep.episode.map { "第 \($0) 集" } ?? "未知集数").font(.subheadline.bold())
                                Text(ep.episodeTitle ?? ep.file.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
