import SwiftUI

@main
struct HarkPlayerApp: App {
    @UIApplicationDelegateAdaptor(OrientationDelegate.self) private var orientationDelegate
    @StateObject private var sources = SourceStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var router = PlaybackRouter.shared
    @StateObject private var settings = AppSettings.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 800 << 20)
        _ = AppActivity.shared
        MPVGuard.checkLastRun()
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


/// Library and settings stay portrait on iPhone; only the player unlocks landscape.
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    @MainActor static func set(_ m: UIInterfaceOrientationMask, force: UIInterfaceOrientationMask? = nil) {
        if UIDevice.current.userInterfaceIdiom == .pad { return }
        mask = m
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            if let f = force { scene.requestGeometryUpdate(.iOS(interfaceOrientations: f)) { _ in } }
        }
    }
    @MainActor static var isLandscape: Bool {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation.isLandscape ?? false
    }
    /// Snap back to portrait without the rotation animation, then close the player without its slide,
    /// so the library reappears already upright (like Infuse/VidHub).
    @MainActor static func leavePlayer(_ then: @escaping () -> Void) {
        let wasLand = isLandscape
        if wasLand { UIView.setAnimationsEnabled(false) }
        set(.portrait, force: .portrait)
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasLand ? 0.12 : 0)) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { then() }
            if wasLand { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { UIView.setAnimationsEnabled(true) } }
        }
    }
}

final class OrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
