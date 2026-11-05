import WidgetKit
import SwiftUI
import AppIntents

struct HarkEntry: TimelineEntry {
    let date: Date
    let items: [FeedItem]
    var page: Int = 0
}

enum WidgetCache {
    static let d = UserDefaults.standard
    static var page: Int {
        get { d.integer(forKey: "widgetPage") }
        set { d.set(newValue, forKey: "widgetPage") }
    }
    static var skipFetch: Bool {
        get { d.bool(forKey: "widgetSkipFetch") }
        set { d.set(newValue, forKey: "widgetSkipFetch") }
    }
    static var items: [FeedItem] {
        get { d.data(forKey: "widgetCache").flatMap { try? JSONDecoder().decode([FeedItem].self, from: $0) } ?? [] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "widgetCache") }
    }
}

/// Shows the next few items without re-downloading.
struct WidgetNextIntent: AppIntent {
    static var title: LocalizedStringResource = "下一组"
    func perform() async throws -> some IntentResult {
        WidgetCache.page += 1
        WidgetCache.skipFetch = true
        return .result()
    }
}

/// Re-downloads the feed and goes back to the newest items.
struct WidgetRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新"
    func perform() async throws -> some IntentResult {
        WidgetCache.page = 0
        WidgetCache.skipFetch = false
        return .result()
    }
}

struct HarkProvider: TimelineProvider {
    func placeholder(in context: Context) -> HarkEntry {
        HarkEntry(date: Date(), items: [FeedItem(title: "Hark 推送的最新消息会显示在这里", link: "", summary: "", date: Date(), guid: "p", source: "Hark 推送")])
    }
    func getSnapshot(in context: Context, completion: @escaping (HarkEntry) -> Void) {
        Task { completion(HarkEntry(date: Date(), items: await Self.load(), page: WidgetCache.page)) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HarkEntry>) -> Void) {
        Task {
            let items = await Self.load()
            let e = HarkEntry(date: Date(), items: items, page: WidgetCache.page)
            completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(1800))))
        }
    }
    static func load() async -> [FeedItem] {
        let cached = WidgetCache.items
        if WidgetCache.skipFetch, !cached.isEmpty {
            WidgetCache.skipFetch = false
            return cached
        }
        WidgetCache.skipFetch = false
        let src = FeedSource(name: "Hark 推送", url: FeedSource.defaultFeed)
        guard let u = URL(string: src.url),
              let r = try? await URLSession.shared.data(from: u) else { return cached }
        let items = FeedParser.parse(r.0, source: src).1
        let top = Array(items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(24))
        if top.isEmpty { return cached }
        WidgetCache.items = top
        return top
    }
}

struct HarkWidgetView: View {
    let entry: HarkEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int {
        switch family {
        case .systemSmall: return 2
        case .systemLarge: return 6
        case .systemMedium: return 3
        default: return 1
        }
    }
    private var isAccessory: Bool {
        family == .accessoryInline || family == .accessoryRectangular || family == .accessoryCircular
    }
    private var visible: [FeedItem] {
        let all = entry.items
        guard !all.isEmpty else { return [] }
        let c = min(count, all.count)
        let start = (max(entry.page, 0) * c) % all.count
        return (0..<c).map { all[(start + $0) % all.count] }
    }

    static func openURL(_ i: FeedItem) -> URL? {
        let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        return URL(string: "harkrss://open?id=\(enc(i.id))&link=\(enc(i.link))")
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label(visible.first?.title ?? "Hark 推送：暂无消息", systemImage: "antenna.radiowaves.left.and.right")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Label("Hark 推送", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption2.weight(.bold))
                    Text(visible.first?.title ?? "暂无消息").font(.caption).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                content
            }
        }
        .widgetURL(visible.first.flatMap(Self.openURL))
        .containerBackground(for: .widget) {
            if isAccessory {
                Color.clear
            } else {
                LinearGradient(colors: [Color.indigo.opacity(0.35), Color.cyan.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Hark 推送", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(intent: WidgetNextIntent()) {
                    Image(systemName: "chevron.down.circle.fill").font(.callout)
                }
                .buttonStyle(.plain)
                Button(intent: WidgetRefreshIntent()) {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.callout)
                }
                .buttonStyle(.plain)
            }
            if visible.isEmpty {
                Text("暂无消息").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, i in
                row(i)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(_ i: FeedItem) -> some View {
        let v = VStack(alignment: .leading, spacing: 2) {
            Text(i.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let d = i.date {
                Text(d, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        if family != .systemSmall, let u = Self.openURL(i) {
            Link(destination: u) { v }
        } else {
            v
        }
    }
}

struct HarkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HarkWidget", provider: HarkProvider()) { entry in
            HarkWidgetView(entry: entry)
        }
        .configurationDisplayName("Hark 推送")
        .description("最新的 Hark 推送。点箭头看下一组，点刷新重新拉取。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct HarkWidgetBundle: WidgetBundle {
    var body: some Widget { HarkWidget() }
}
