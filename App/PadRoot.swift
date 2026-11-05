import SwiftUI

/// iPad: sidebar, article list and article side by side.
struct PadRootView: View {
    @EnvironmentObject var store: FeedStore
    @Binding var selected: FeedItem?
    @State private var pane: Pane? = .timeline(.all)

    enum Pane: Hashable { case timeline(FeedStore.Scope), starred, later, sources, settings }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    Label("时间线", systemImage: "antenna.radiowaves.left.and.right")
                        .badge(store.unreadTotal)
                        .tag(Pane.timeline(.all))
                    Label("收藏", systemImage: "star").tag(Pane.starred)
                    Label("稍后读", systemImage: "clock").tag(Pane.later)
                }
                if !store.groups.isEmpty {
                    Section("分组") {
                        ForEach(store.groups, id: \.self) { g in
                            Label(g, systemImage: "folder").tag(Pane.timeline(.group(g)))
                        }
                    }
                }
                Section {
                    Label("订阅", systemImage: "list.bullet.rectangle").tag(Pane.sources)
                    Label("设置", systemImage: "gearshape").tag(Pane.settings)
                }
            }
            .navigationTitle("Hark 推送")
        } content: {
            NavigationStack { column }
        } detail: {
            NavigationStack {
                if let s = selected {
                    ArticleView(item: s).id(s.id)
                } else {
                    ZStack(alignment: .bottom) {
                        AuroraBackground().opacity(0.45)
                        ContentUnavailableView("选一篇文章", systemImage: "doc.richtext",
                                               description: Text("在中间的列表里点一篇，就会在这里打开。"))
                        MiniPlayerBar().padding(14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var column: some View {
        switch pane ?? .timeline(.all) {
        case .timeline(let s): ItemsScreen(mode: .timeline, scope: s, selection: $selected).id(pane)
        case .starred: ItemsScreen(mode: .starred, selection: $selected)
        case .later: ItemsScreen(mode: .later, selection: $selected)
        case .sources: SourcesView()
        case .settings: SettingsView()
        }
    }
}
