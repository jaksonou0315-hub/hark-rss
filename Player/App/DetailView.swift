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
    @State private var details: TMDBDetails?
    @State private var expanded = false
    @State private var showAllEpisodes = false

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
                                if item.isTV { episodes(item) } else if item.files.count > 1 { versions(item) }
                                cast
                                genres
                                recent(item)
                            }
                            .padding(.top, 18)
                            .padding(.bottom, 50)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea(edges: .top)
                    topBar(item)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
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
                        Button { play(ep, item) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                PosterImage(url: ep.still ?? item.backdrop, title: "")
                                    .frame(width: 232, height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(alignment: .bottomLeading) {
                                        if marks.watched.contains(ep.id) {
                                            Image(systemName: "checkmark.circle.fill").padding(8)
                                        }
                                    }
                                Text(epTitle(ep)).font(.subheadline.weight(.medium)).lineLimit(1)
                                    .frame(width: 232, alignment: .leading)
                            }
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
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
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

    @ViewBuilder private func recent(_ item: LibraryItem) -> some View {
        let list = Array(library.items.sorted { $0.added > $1.added }.prefix(15))
        if list.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                Text("最近添加").font(.title2.bold()).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(list) { it in
                            NavigationLink(value: it) {
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
                                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(Color.white, lineWidth: it.id == item.id ? 3 : 0).padding(-3))
                                    Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(it.isTV ? "共\(max(1, it.seasons.count))季" : (it.year.map { String($0) } ?? "电影"))
                                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                                }
                                .frame(width: 124)
                            }
                            .buttonStyle(.plain)
                            .disabled(it.id == item.id)
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
                Button { marks.toggle(\.watched, item.id) } label: {
                    Label(marks.watched.contains(item.id) ? "标为未看" : "标为已看", systemImage: "flag")
                }
                Button { marks.toggle(\.favorites, item.id) } label: {
                    Label(marks.favorites.contains(item.id) ? "取消收藏" : "收藏", systemImage: "heart")
                }
                if !item.isTV {
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

    // MARK: play

    private func firstPlayable(_ item: LibraryItem) -> LibraryFile? {
        if item.isTV {
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
                    Button { dismiss(); play(ep) } label: {
                        HStack(spacing: 12) {
                            PosterImage(url: ep.still ?? item.backdrop, title: "")
                                .frame(width: 128, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ep.episode.map { "第 \($0) 集" } ?? "未知集数").font(.subheadline.bold())
                                Text(ep.episodeTitle ?? ep.file.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
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
