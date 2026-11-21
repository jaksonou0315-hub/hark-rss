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

    var body: some View {
        TabView(selection: $tab) {
            Tab("媒体库", systemImage: "play.rectangle.fill", value: 0) { HomeView() }
            Tab("文件源", systemImage: "folder", value: 1) { FavoriteSourcesView() }
            Tab("服务器", systemImage: "server.rack", value: 2) { SourcesView(mode: .servers) }
            Tab("设置", systemImage: "gearshape", value: 3) { SettingsView() }
            if lastTab == 1 {
                Tab("添加", systemImage: "plus", value: 4, role: .search) { Color.clear }
            } else {
                Tab(value: 4, role: .search) { LibrarySearchView() }
            }
        }
        .onChange(of: tab) { old, new in
            if new == 4 && lastTab == 1 {
                // On 文件源 the search slot is a ＋ that opens 文件源管理.
                tab = 1
                NotificationCenter.default.post(name: .openSourceManager, object: nil)
                return
            }
            if new != 4 { lastTab = new }
        }
        .minimizingTabBar()

        .fullScreenCover(item: $router.request) { r in
            PlayerEntry(request: r)
        }
    }
}
