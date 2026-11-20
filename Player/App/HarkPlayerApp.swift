import SwiftUI

@main
struct HarkPlayerApp: App {
    @StateObject private var sources = SourceStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var router = PlaybackRouter.shared
    @StateObject private var settings = AppSettings.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 800 << 20)
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

    var body: some View {
        TabView(selection: $tab) {
            Tab("媒体库", systemImage: "play.rectangle.fill", value: 0) { HomeView() }
            Tab("文件源", systemImage: "folder", value: 1) { SourcesView(mode: .files) }
            Tab("服务器", systemImage: "server.rack", value: 2) { SourcesView(mode: .servers) }
            Tab("设置", systemImage: "gearshape", value: 3) { SettingsView() }
            Tab(value: 4, role: .search) { LibrarySearchView() }
        }
        .minimizingTabBar()
        .fullScreenCover(item: $router.request) { r in
            PlayerEntry(request: r)
        }
    }
}
