import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct HarkRSSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = FeedStore.shared

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
        .backgroundTask(.appRefresh("com.ouyanghong.harkrss.refresh")) {
            await FeedStore.shared.backgroundRefresh()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: FeedStore
    @Environment(\.scenePhase) private var phase
    @State private var tab = UserDefaults.standard.integer(forKey: "HarkTab")

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { ItemsScreen(mode: .timeline) }
                .tabItem { Label("时间线", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(0)
                .badge(store.unreadTotal)
            NavigationStack { ItemsScreen(mode: .starred) }
                .tabItem { Label("收藏", systemImage: "star") }
                .tag(1)
            NavigationStack { ItemsScreen(mode: .later) }
                .tabItem { Label("稍后读", systemImage: "clock") }
                .tag(2)
            NavigationStack { SourcesView() }
                .tabItem { Label("订阅", systemImage: "list.bullet.rectangle") }
                .tag(3)
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(4)
        }
        .modifier(TabMinimize())
        .task { await store.refresh() }
        .onChange(of: phase) { p in
            if p == .active { Task { await store.refresh() } }
            if p == .background { store.scheduleBackgroundRefresh() }
        }
    }
}

struct TabMinimize: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
