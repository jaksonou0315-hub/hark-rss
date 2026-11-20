import SwiftUI

@main
struct HarkPlayerApp: App {
    @StateObject private var sources = SourceStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var router = PlaybackRouter.shared
    @StateObject private var settings = AppSettings.shared

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
            LibraryView()
                .tabItem { Label("媒体库", systemImage: "square.grid.2x2") }
                .tag(0)
            SourcesView()
                .tabItem { Label("浏览", systemImage: "externaldrive") }
                .tag(1)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(2)
        }
        .minimizingTabBar()
        .fullScreenCover(item: $router.request) { r in
            PlayerEntry(request: r)
        }
    }
}
