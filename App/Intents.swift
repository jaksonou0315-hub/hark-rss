import AppIntents

struct RefreshFeedsIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新 Hark 推送"
    static var description = IntentDescription("拉取所有订阅源的新文章。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let n = await FeedStore.shared.refresh()
        let unread = FeedStore.shared.unreadTotal
        let text = n == 0 ? "没有新文章，现在有 \(unread) 篇未读" : "收到 \(n) 篇新文章，共 \(unread) 篇未读"
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct UnreadCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Hark 推送未读数"
    static var description = IntentDescription("告诉你还有几篇没读。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let n = FeedStore.shared.unreadTotal
        return .result(value: n, dialog: IntentDialog(stringLiteral: n == 0 ? "全部读完了" : "还有 \(n) 篇未读"))
    }
}

struct AddFeedIntent: AppIntent {
    static var title: LocalizedStringResource = "添加到 Hark 推送"
    static var description = IntentDescription("把网址加为订阅。可以放进分享菜单的快捷指令里用。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "网址或 RSS 地址")
    var address: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = FeedStore.shared
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = RSSHub.route(fromURL: input) {
            store.addSource(name: r.name, url: r.url, group: r.group)
            await store.refresh()
            return .result(dialog: IntentDialog(stringLiteral: "已添加 \(r.name)"))
        }
        let found = (try? await FeedDiscovery.discover(input)) ?? []
        guard let c = found.first else {
            return .result(dialog: IntentDialog(stringLiteral: "没找到这个网址的订阅源"))
        }
        store.addSource(name: c.title, url: c.url, group: "")
        await store.refresh()
        return .result(dialog: IntentDialog(stringLiteral: "已添加 \(c.title)"))
    }
}

struct HarkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RefreshFeedsIntent(),
                    phrases: ["刷新\(.applicationName)", "Refresh \(.applicationName)"],
                    shortTitle: "刷新订阅", systemImageName: "arrow.clockwise")
        AppShortcut(intent: UnreadCountIntent(),
                    phrases: ["\(.applicationName)有几条未读", "\(.applicationName) unread count"],
                    shortTitle: "未读数", systemImageName: "circle.inset.filled")
        AppShortcut(intent: AddFeedIntent(),
                    phrases: ["用\(.applicationName)添加订阅", "Add a feed to \(.applicationName)"],
                    shortTitle: "添加订阅", systemImageName: "plus.circle")
    }
}
