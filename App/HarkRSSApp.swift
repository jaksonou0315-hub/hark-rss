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
    @ObservedObject private var bar = TabBarState.shared
    @ObservedObject private var player = Player.shared
    @State private var tab = UserDefaults.standard.integer(forKey: "HarkTab")

    var body: some View {
        ZStack(alignment: .bottom) {
            page(0) { ItemsScreen(mode: .timeline) }
            page(1) { ItemsScreen(mode: .starred) }
            page(2) { ItemsScreen(mode: .later) }
            page(3) { SourcesView() }
            page(4) { SettingsView() }

            if bar.actionsOpen {
                Color.black.opacity(0.12).ignoresSafeArea()
                    .onTapGesture { bar.actionsOpen = false }
                    .transition(.opacity)
                    .zIndex(5)
            }
            ExpandableTabBar(selection: $tab)
                .zIndex(10)
        }
        .onChange(of: tab) { _ in bar.collapsed = false }
        .task { await store.refresh() }
        .onChange(of: phase) { p in
            if p == .active { Task { await store.refresh() } }
            if p == .background { store.scheduleBackgroundRefresh() }
        }
    }

    /// Each tab keeps its own navigation stack alive; only the selected one is visible.
    private func page<C: View>(_ i: Int, @ViewBuilder _ content: () -> C) -> some View {
        NavigationStack { content() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: player.current == nil ? 70 : 136)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 24).onChanged { v in
                guard abs(v.translation.height) > abs(v.translation.width) else { return }
                if v.translation.height < -50, !bar.collapsed { bar.collapsed = true }
                else if v.translation.height > 50, bar.collapsed { bar.collapsed = false }
            })
            .opacity(tab == i ? 1 : 0)
            .allowsHitTesting(tab == i)
            .accessibilityHidden(tab != i)
            .zIndex(tab == i ? 1 : 0)
    }
}
