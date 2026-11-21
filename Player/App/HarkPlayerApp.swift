import SwiftUI

@main
struct HarkPlayerApp: App {
    @StateObject private var sources = SourceStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var router = PlaybackRouter.shared
    @StateObject private var settings = AppSettings.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 800 << 20)
        _ = AppActivity.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sources)
                .environmentObject(library)
                .environmentObject(router)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .tint(.pink)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var router: PlaybackRouter
    @State private var tab = 0
    @State private var lastTab = 0
    @ObservedObject private var favNav = FavoritesNav.shared
    @State private var favSearch = false     // follows favNav.inFolder only while 文件源 is the visible tab

    var body: some View {
        TabView(selection: $tab) {
            Tab("媒体库", systemImage: "play.rectangle.fill", value: 0) { HomeView() }
            Tab("文件源", systemImage: "folder", value: 1) { FavoriteSourcesView() }
            Tab("服务器", systemImage: "server.rack", value: 2) { SourcesView(mode: .servers) }
            Tab("设置", systemImage: "gearshape", value: 3) { SettingsView() }
            if lastTab == 1 && favSearch {
                Tab(value: 4, role: .search) { FavoriteFilesSearchView() }
            } else if lastTab == 1 {
                Tab("添加", systemImage: "plus", value: 4, role: .search) { Color.clear }
            } else {
                Tab(value: 4, role: .search) { LibrarySearchView() }
            }
        }
        .onChange(of: tab) { old, new in
            if new == 4 && lastTab == 1 && !favSearch {
                // On 文件源 the search slot is a ＋ that opens 文件源管理.
                tab = 1
                NotificationCenter.default.post(name: .openSourceManager, object: nil)
                return
            }
            if new != 4 { lastTab = new }
        }
        .onChange(of: favNav.inFolder) { _, v in if tab == 1 { favSearch = v } }
        .minimizingTabBar()

        .fullScreenCover(item: $router.request) { r in
            PlayerEntry(request: r)
        }
    }
}
