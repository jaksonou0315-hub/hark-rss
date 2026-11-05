import WidgetKit
import SwiftUI

struct HarkEntry: TimelineEntry {
    let date: Date
    let items: [FeedItem]
}

struct HarkProvider: TimelineProvider {
    func placeholder(in context: Context) -> HarkEntry {
        HarkEntry(date: Date(), items: [FeedItem(title: "Hark 推送的最新消息会显示在这里", link: "", summary: "", date: Date(), guid: "p", source: "Hark 推送")])
    }
    func getSnapshot(in context: Context, completion: @escaping (HarkEntry) -> Void) {
        Task { completion(HarkEntry(date: Date(), items: await Self.load())) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HarkEntry>) -> Void) {
        Task {
            let items = await Self.load()
            completion(Timeline(entries: [HarkEntry(date: Date(), items: items)], policy: .after(Date().addingTimeInterval(1800))))
        }
    }
    static func load() async -> [FeedItem] {
        let src = FeedSource(name: "Hark 推送", url: FeedSource.defaultFeed)
        guard let u = URL(string: src.url),
              let r = try? await URLSession.shared.data(from: u) else { return [] }
        let items = FeedParser.parse(r.0, source: src).1
        return Array(items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(6))
    }
}

struct HarkWidgetView: View {
    let entry: HarkEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int {
        switch family {
        case .systemSmall: return 2
        case .systemLarge: return 6
        default: return 3
        }
    }

    var body: some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(for: .widget) {
                LinearGradient(colors: [Color.indigo.opacity(0.35), Color.cyan.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        } else {
            content.padding()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Hark 推送", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            if entry.items.isEmpty {
                Text("暂无消息").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(entry.items.prefix(count).enumerated()), id: \.offset) { _, i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(i.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let d = i.date {
                        Text(d, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct HarkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HarkWidget", provider: HarkProvider()) { entry in
            HarkWidgetView(entry: entry)
        }
        .configurationDisplayName("Hark 推送")
        .description("显示最新几条 Hark 推送。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct HarkWidgetBundle: WidgetBundle {
    var body: some Widget { HarkWidget() }
}
