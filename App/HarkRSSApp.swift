import SwiftUI
import UserNotifications

/// Shows banners while the app is open. Not UIKit: a plain notification-center delegate.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct HarkRSSApp: App {
    @StateObject private var store = FeedStore.shared

    init() { UNUserNotificationCenter.current().delegate = NotificationDelegate.shared }

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
    @State private var timelinePath: [FeedItem] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            page(0, path: $timelinePath) { ItemsScreen(mode: .timeline) }
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
        .task {
            // Demo hook for simulator screenshots: open the first article with a picture.
            guard UserDefaults.standard.bool(forKey: "HarkOpenFirst") else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let list = store.timeline(scope: .all)
            if let i = list.first(where: { !$0.imageURL.isEmpty }) ?? list.first { timelinePath = [i] }
        }
        .onChange(of: phase) { p in
            if p == .active { Task { await store.refresh() } }
            if p == .background { store.scheduleBackgroundRefresh() }
        }
    }

    /// Each tab keeps its own navigation stack alive; only the selected one is visible.
    private func page<C: View>(_ i: Int, path: Binding<[FeedItem]>? = nil, @ViewBuilder _ content: () -> C) -> some View {
        Group {
            if let path { NavigationStack(path: path) { content() } } else { NavigationStack { content() } }
        }
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
