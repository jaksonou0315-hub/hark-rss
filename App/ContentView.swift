import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: FeedStore
    @State private var showSources = false
    var body: some View {
        NavigationStack {
            List {
                if let e = store.error { Text(e).font(.footnote).foregroundStyle(.red) }
                if store.items.isEmpty && !store.loading {
                    ContentUnavailableCompat()
                }
                ForEach(store.items) { item in
                    NavigationLink(value: item) { Row(item: item, unread: !store.readIDs.contains(item.id)) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Hark 推送")
            .navigationDestination(for: FeedItem.self) { DetailView(item: $0) }
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("全部已读") { store.markAllRead() }.disabled(store.unread == 0) }
                ToolbarItem(placement: .navigationBarTrailing) { Button { showSources = true } label: { Image(systemName: "dot.radiowaves.up.forward") } }
            }
            .overlay { if store.loading && store.items.isEmpty { ProgressView() } }
            .sheet(isPresented: $showSources) { SourcesView() }
            .task { await store.refresh() }
        }
    }
}

struct ContentUnavailableCompat: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
            Text("还没有消息").font(.headline)
            Text("下拉刷新，或在右上角添加订阅源").font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 60).listRowSeparator(.hidden)
    }
}

struct Row: View {
    let item: FeedItem; let unread: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(unread ? Color.accentColor : .clear).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(unread ? .semibold : .regular)).lineLimit(2)
                Text(plain(item.summary)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Text(item.source)
                    if let d = item.date { Text("·"); Text(d, format: .relative(presentation: .named)) }
                }.font(.caption).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 4)
    }
}

func plain(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
}

struct DetailView: View {
    @EnvironmentObject var store: FeedStore
    let item: FeedItem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.title2.bold())
                HStack { Text(item.source); if let d = item.date { Text(d, style: .date); Text(d, style: .time) } }
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(attributed(item.summary)).textSelection(.enabled)
                if let u = URL(string: item.link), !item.link.isEmpty {
                    Link(destination: u) { Label("打开原文", systemImage: "safari") }.padding(.top)
                }
            }.padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.readIDs.insert(item.id) }
    }
    func attributed(_ html: String) -> AttributedString {
        let s = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>|</li>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<li>", with: "• ")
        return AttributedString(plain(s.replacingOccurrences(of: "\n", with: "⏎")).replacingOccurrences(of: "⏎", with: "\n"))
    }
}

struct SourcesView: View {
    @EnvironmentObject var store: FeedStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""; @State private var url = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("订阅源") {
                    ForEach(store.sources) { s in
                        VStack(alignment: .leading) { Text(s.name); Text(s.url).font(.caption2).foregroundStyle(.secondary) }
                    }.onDelete { store.sources.remove(atOffsets: $0) }
                }
                Section("添加 RSS / Atom") {
                    TextField("名称", text: $name)
                    TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("添加") {
                        store.sources.append(FeedSource(name: name.isEmpty ? url : name, url: url)); name = ""; url = ""
                        Task { await store.refresh() }
                    }.disabled(URL(string: url)?.scheme == nil)
                }
            }
            .navigationTitle("订阅源")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
