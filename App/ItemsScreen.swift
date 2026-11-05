import SwiftUI

enum ListMode { case timeline, starred, later }

struct ItemsScreen: View {
    let mode: ListMode
    var selection: Binding<FeedItem?>?
    @EnvironmentObject var store: FeedStore
    @State private var search = ""
    @State private var unreadOnly = false
    @State private var scope: FeedStore.Scope
    @AppStorage("compactList") private var compact = false
    @AppStorage("groupByDay") private var groupByDay = true

    init(mode: ListMode, scope: FeedStore.Scope = .all, selection: Binding<FeedItem?>? = nil) {
        self.mode = mode
        self.selection = selection
        _scope = State(initialValue: scope)
    }

    private var title: String {
        switch mode {
        case .starred: return "收藏"
        case .later: return "稍后读"
        case .timeline:
            switch scope {
            case .all: return "Hark 推送"
            case .group(let g): return g
            case .source(let id): return store.sources.first { $0.id == id }?.name ?? "订阅源"
            }
        }
    }

    private var list: [FeedItem] {
        var l: [FeedItem]
        switch mode {
        case .timeline: l = store.timeline(scope: scope)
        case .starred: l = store.starredItems
        case .later: l = store.laterItems
        }
        if unreadOnly { l = l.filter { !store.isRead($0) } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            l = l.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q) || $0.source.localizedCaseInsensitiveContains(q) }
        }
        return l
    }

    private struct DaySection: Identifiable {
        let id: String
        let items: [FeedItem]
    }

    private func sections(_ items: [FeedItem]) -> [DaySection] {
        guard groupByDay else { return [DaySection(id: "", items: items)] }
        let cal = Calendar.current
        var order: [String] = []
        var map: [String: [FeedItem]] = [:]
        for i in items {
            let k = Self.dayTitle(i.date ?? i.firstSeen, cal)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(i)
        }
        return order.map { DaySection(id: $0, items: map[$0] ?? []) }
    }

    static func dayTitle(_ d: Date?, _ cal: Calendar) -> String {
        guard let d else { return "更早" }
        if d > Date() || cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 99
        if days < 7 { return d.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN"))) }
        return "更早"
    }

    var body: some View {
        let items = list
        ZStack {
            AuroraBackground()
            List {
                if mode == .timeline, let e = store.lastError {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: .red.opacity(0.2))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if items.isEmpty {
                    EmptyHint(mode: mode, searching: !search.isEmpty)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(sections(items)) { sec in
                    Section {
                        ForEach(sec.items) { row($0) }
                    } header: {
                        if !sec.id.isEmpty {
                            Text(sec.id)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .refreshable { await store.refresh() }
        }
        .navigationTitle(title)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题、内容、来源")
        .navigationDestination(for: FeedItem.self) { ArticleView(item: $0) }
        .toolbar { toolbarContent }
    }

    private func row(_ item: FeedItem) -> some View {
        let read = store.isRead(item)
        let starred = store.isStarred(item)
        let later = store.isLater(item)
        return cell(item)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: compact ? 4 : 6, leading: 14, bottom: compact ? 4 : 6, trailing: 14))
            .contextMenu { ItemActions(item: item) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { store.toggleRead(item) } label: {
                    Label(read ? "未读" : "已读", systemImage: read ? "circle" : "checkmark.circle")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { store.toggleStar(item) } label: {
                    Label(starred ? "取消收藏" : "收藏", systemImage: starred ? "star.slash" : "star")
                }
                .tint(.yellow)
                Button { store.toggleLater(item) } label: {
                    Label(later ? "移出" : "稍后读", systemImage: "clock")
                }
                .tint(.orange)
            }
    }

    @ViewBuilder
    private func cell(_ item: FeedItem) -> some View {
        if let selection {
            Button { selection.wrappedValue = item } label: { card(item) }
                .buttonStyle(.plain)
        } else {
            card(item)
                .background(NavigationLink(value: item) { EmptyView() }.opacity(0))
        }
    }

    @ViewBuilder
    private func card(_ item: FeedItem) -> some View {
        if compact { CompactRow(item: item) } else { ItemCard(item: item) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if mode == .timeline && selection == nil {
                Menu {
                    Button { scope = .all } label: { Label("全部", systemImage: "tray.full") }
                    Section("分组") {
                        ForEach(store.groups, id: \.self) { g in
                            Button { scope = .group(g) } label: { Label(g, systemImage: "folder") }
                        }
                    }
                    Section("订阅源") {
                        ForEach(store.sources) { s in
                            Button { scope = .source(s.id) } label: { Label(s.name, systemImage: "dot.radiowaves.left.and.right") }
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Toggle(isOn: $unreadOnly) { Label("只看未读", systemImage: "circle.inset.filled") }
                Toggle(isOn: $groupByDay) { Label("按日期分组", systemImage: "calendar") }
                Toggle(isOn: $compact) { Label("紧凑列表", systemImage: "list.bullet") }
                Button { store.markAllRead(list) } label: { Label("全部标为已读", systemImage: "checkmark.circle") }
                if mode == .timeline {
                    Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                }
            } label: {
                if store.loading { ProgressView() } else { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

/// One-line style row for the compact list.
struct CompactRow: View {
    let item: FeedItem
    @EnvironmentObject var store: FeedStore

    var body: some View {
        let read = store.isRead(item)
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(read ? Color.clear : Color.accentColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(read ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(item.source)
                    if let d = item.date { Text("· " + d.formatted(date: .omitted, time: .shortened)) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.hasMedia { Image(systemName: item.isVideo ? "play.rectangle.fill" : "waveform").font(.caption2) }
            if store.isStarred(item) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
            if store.isLater(item) { Image(systemName: "clock.fill").font(.caption2).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: store.isHighlighted(item) ? Color.orange.opacity(0.3) : nil)
    }
}

struct ItemCard: View {
    let item: FeedItem
    @EnvironmentObject var store: FeedStore

    var body: some View {
        let read = store.isRead(item)
        let hi = store.isHighlighted(item)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if !read { Circle().fill(Color.accentColor).frame(width: 8, height: 8) }
                    Text(item.source).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    if let d = item.date {
                        Text("· " + d.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if item.hasMedia { Image(systemName: item.isVideo ? "play.rectangle.fill" : "waveform").font(.caption) }
                    if store.isStarred(item) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    if store.isLater(item) { Image(systemName: "clock.fill").font(.caption).foregroundStyle(.orange) }
                }
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(read ? .secondary : .primary)
                    .lineLimit(3)
                let s = item.plainSummary
                if !s.isEmpty && s != item.title {
                    Text(s).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let u = URL(string: item.imageURL), !item.imageURL.isEmpty {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), tint: hi ? Color.orange.opacity(0.3) : nil, interactive: true)
    }
}

struct ItemActions: View {
    let item: FeedItem
    @EnvironmentObject var store: FeedStore
    var body: some View {
        Button { store.toggleRead(item) } label: {
            Label(store.isRead(item) ? "标为未读" : "标为已读", systemImage: store.isRead(item) ? "circle" : "checkmark.circle")
        }
        Button { store.toggleStar(item) } label: {
            Label(store.isStarred(item) ? "取消收藏" : "收藏", systemImage: store.isStarred(item) ? "star.slash" : "star")
        }
        Button { store.toggleLater(item) } label: {
            Label(store.isLater(item) ? "移出稍后读" : "稍后读", systemImage: "clock")
        }
        if !item.link.isEmpty, let u = URL(string: item.link) {
            ShareLink(item: u) { Label("分享", systemImage: "square.and.arrow.up") }
        }
    }
}

struct EmptyHint: View {
    let mode: ListMode
    let searching: Bool
    private var icon: String {
        if searching { return "magnifyingglass" }
        switch mode { case .timeline: return "tray"; case .starred: return "star"; case .later: return "clock" }
    }
    private var text: String {
        if searching { return "没有匹配的文章" }
        switch mode {
        case .timeline: return "还没有消息，下拉刷新试试"
        case .starred: return "长按文章或在文章页点星标即可收藏"
        case .later: return "长按文章选择「稍后读」"
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).symbolRenderingMode(.hierarchical)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(28)
        .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
