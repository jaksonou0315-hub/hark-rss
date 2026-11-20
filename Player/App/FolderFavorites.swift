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
        if contains(s, d) { items.removeAll { $0.id == fid(s, d) } }
        else { items.append(FavoriteFolder(sourceId: s.id, dir: d, title: d?.name ?? s.name)) }
        save()
    }
    func remove(_ f: FavoriteFolder) { items.removeAll { $0.id == f.id }; save() }
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
                                    }
                                    .padding(.vertical, 4)
                                }
                                .listRowBackground(Color.clear)
                                .swipeActions {
                                    Button(role: .destructive) { favs.remove(f) } label: { Label("取消收藏", systemImage: "star.slash") }
                                }
                                .contextMenu {
                                    Button(role: .destructive) { favs.remove(f) } label: { Label("取消收藏", systemImage: "star.slash") }
                                }
                            }
                        }
                        .onMove { favs.move(from: $0, to: $1) }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("文件源")
            .navigationDestination(for: BrowseTarget.self) { FolderView(target: $0) }
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
