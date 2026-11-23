import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @State private var filter = 0
    @State private var showFolders = false
    @State private var search = ""

    private var shown: [LibraryItem] {
        let base: [LibraryItem]
        switch filter {
        case 1: base = library.movies
        case 2: base = library.shows
        default: base = library.items.sorted { $0.added > $1.added }
        }
        guard !search.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(search) || ($0.originalTitle ?? "").localizedCaseInsensitiveContains(search) }
    }

    private let cols = [GridItem(.adaptive(minimum: 108, maximum: 170), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("", selection: $filter) {
                            Text("全部").tag(0); Text("电影").tag(1); Text("剧集").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        if library.scanning {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(library.progress).font(.footnote).lineLimit(1)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glass(in: Capsule())
                            .padding(.horizontal)
                        }
                        if let r = library.lastResult, !library.scanning {
                            Label(r, systemImage: library.items.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                                .font(.footnote).padding(12)
                                .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding(.horizontal)
                                .onTapGesture { library.lastResult = nil }
                        }
                        if settings.tmdbKey.isEmpty && !library.items.isEmpty {
                            Label("在设置里填写 TMDB API Key，即可自动获取海报和简介", systemImage: "info.circle")
                                .font(.footnote).padding(12)
                                .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding(.horizontal)
                        }

                        if library.items.isEmpty && !library.scanning {
                            emptyState
                        } else {
                            LazyVGrid(columns: cols, spacing: 18) {
                                ForEach(shown) { item in
                                    NavigationLink(value: item) { PosterCard(item: item) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
                .refreshable { await library.scan() }
            }
            .navigationTitle("媒体库")
            .searchable(text: $search, prompt: "搜索影片")
            .navigationDestination(for: LibraryItem.self) { DetailView(itemId: $0.id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await library.scan() } } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                        Button { showFolders = true } label: { Label("管理媒体库文件夹", systemImage: "folder.badge.gearshape") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showFolders) { LibraryFoldersView() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 52)).foregroundStyle(.pink)
            Text("媒体库还是空的").font(.title3.bold())
            Text("到「浏览」里添加 SMB、WebDAV、Emby、Jellyfin 或网盘，长按任意文件夹或视频选择「添加到媒体库」，即可生成海报墙。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding()
    }
}

struct PosterCard: View {
    let item: LibraryItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: item.poster, title: item.title)
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let r = item.shownRating, r > 0 {
                        Text(String(format: "%.1f", r)).font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .glass(in: Capsule(), tint: .black.opacity(0.3))
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(item.isTV ? "剧集 · \(item.files.count) 集" : (item.year.map { String($0) } ?? "电影"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct LibraryFoldersView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var sources: SourceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.folders) { f in
                        VStack(alignment: .leading) {
                            Text(f.dir.name)
                            Text(sources.source(f.sourceId)?.name ?? "已删除的来源").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in idx.map { library.folders[$0] }.forEach(library.removeFolder) }
                } footer: {
                    Text("在「浏览」中长按文件夹即可添加。左滑可移除。")
                }
                Section {
                    Button("立即重新扫描") { Task { await library.scan() } }
                    Button("清空海报缓存并重建", role: .destructive) { library.clear(); Task { await library.scan() } }
                }
            }
            .navigationTitle("媒体库文件夹")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
