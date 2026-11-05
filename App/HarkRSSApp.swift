import SwiftUI
import UIKit
import UserNotifications
import CoreSpotlight

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

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // Disk-backed cache for thumbnails and article images (AsyncImage uses the shared session).
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20, diskPath: "harkrss-images")
    }

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
    @Environment(\.openURL) private var openURL
    @ObservedObject private var bar = TabBarState.shared
    @ObservedObject private var player = Player.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var tab = Demo.int("HarkTab")
    @State private var timelinePath: [FeedItem] = []
    @State private var padSelected: FeedItem?
    @State private var addRequest: AddRequest?

    struct AddRequest: Identifiable {
        let id = UUID()
        let url: String
    }

    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    var body: some View {
        Group {
            if isPad { PadRootView(selected: $padSelected) } else { phone }
        }
        .task {
            await store.refresh()
            store.reindexSpotlight()
        }
        .task { await demoOpenFirst() }
        .onChange(of: phase) { p in
            if p == .active { Task { await store.refresh() } }
            if p == .background { store.scheduleBackgroundRefresh() }
        }
        .onOpenURL { handle($0) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { open(id: id, link: nil) }
        }
        .sheet(item: $addRequest) { r in AddSourceView(initialInput: r.url).environmentObject(store) }
    }

    private var phone: some View {
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
            if !bar.hidden {
                ExpandableTabBar(selection: $tab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: bar.hidden)
        .onChange(of: tab) { _ in bar.collapsed = false }
    }

    /// harkrss://add?url=…  adds a feed;  harkrss://open?id=…&link=…  opens an article (used by the widget).
    private func handle(_ url: URL) {
        guard url.scheme == "harkrss" else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String? = { k in q.first { $0.name == k }?.value }
        switch url.host {
        case "add":
            if let u = value("url"), !u.isEmpty { addRequest = AddRequest(url: u) }
        case "open":
            open(id: value("id") ?? "", link: value("link"))
        default:
            break
        }
    }

    private func open(id: String, link: String?) {
        let found = store.item(withID: id) ?? link.flatMap { l in store.items.first { $0.link == l } }
        if let item = found {
            if isPad {
                padSelected = item
            } else {
                bar.actionsOpen = false
                tab = 0
                timelinePath = [item]
            }
        } else if let l = link, let u = URL(string: l) {
            openURL(u)
        }
    }

    private func demoOpenFirst() async {
        #if DEBUG
        // Simulator screenshots: open the first article with a picture.
        guard UserDefaults.standard.bool(forKey: "HarkOpenFirst") else { return }
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        let list = store.timeline(scope: .all)
        if let i = list.first(where: { !$0.imageURL.isEmpty }) ?? list.first { timelinePath = [i] }
        #endif
    }

    private var barInset: CGFloat {
        if bar.hidden { return 0 }
        return (player.current == nil && speaker.item == nil) ? 70 : 136
    }

    /// Each tab keeps its own navigation stack alive; only the selected one is visible.
    private func page<C: View>(_ i: Int, path: Binding<[FeedItem]>? = nil, @ViewBuilder _ content: () -> C) -> some View {
        Group {
            if let path { NavigationStack(path: path) { content() } } else { NavigationStack { content() } }
        }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: barInset)
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
