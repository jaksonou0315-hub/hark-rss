import SwiftUI

/// A small hand-picked directory of feeds.
enum FeedCatalog {
    struct Entry: Identifiable, Hashable {
        var id: String { url }
        let name: String
        let url: String
        let note: String
    }
    struct Category: Identifiable {
        var id: String { name }
        let name: String
        let icon: String
        let entries: [Entry]
    }

    static let categories: [Category] = [
        Category(name: "科技", icon: "cpu", entries: [
            Entry(name: "少数派", url: "https://sspai.com/feed", note: "数字生活、效率工具"),
            Entry(name: "爱范儿", url: "https://www.ifanr.com/feed", note: "科技新闻和评测"),
            Entry(name: "IT之家", url: "https://www.ithome.com/rss/", note: "快讯，更新很勤"),
            Entry(name: "36氪", url: "https://36kr.com/feed", note: "创投和商业科技"),
            Entry(name: "The Verge", url: "https://www.theverge.com/rss/index.xml", note: "英文科技媒体"),
            Entry(name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", note: "英文深度科技"),
            Entry(name: "Hacker News", url: "https://hnrss.org/frontpage", note: "程序员社区首页"),
            Entry(name: "9to5Mac", url: "https://9to5mac.com/feed/", note: "苹果新闻"),
            Entry(name: "MacRumors", url: "https://feeds.macrumors.com/MacRumors-All", note: "苹果传闻"),
            Entry(name: "Apple Newsroom", url: "https://www.apple.com/newsroom/rss-feed.rss", note: "苹果官方新闻"),
        ]),
        Category(name: "新闻", icon: "newspaper", entries: [
            Entry(name: "BBC 中文", url: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml", note: "简体中文国际新闻"),
            Entry(name: "纽约时报中文网", url: "https://cn.nytimes.com/rss/", note: "中文版"),
            Entry(name: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml", note: "英文国际新闻"),
            Entry(name: "The Guardian World", url: "https://www.theguardian.com/world/rss", note: "英文国际新闻"),
            Entry(name: "NPR News", url: "https://feeds.npr.org/1001/rss.xml", note: "美国新闻"),
        ]),
        Category(name: "博客", icon: "text.book.closed", entries: [
            Entry(name: "阮一峰的网络日志", url: "https://www.ruanyifeng.com/blog/atom.xml", note: "科技爱好者周刊"),
            Entry(name: "酷壳 CoolShell", url: "https://coolshell.cn/feed", note: "程序员技术博客"),
            Entry(name: "Daring Fireball", url: "https://daringfireball.net/feeds/main", note: "苹果评论"),
            Entry(name: "Simon Willison", url: "https://simonwillison.net/atom/everything/", note: "AI 和开发"),
            Entry(name: "Smashing Magazine", url: "https://www.smashingmagazine.com/feed/", note: "设计与前端"),
        ]),
        Category(name: "播客", icon: "headphones", entries: [
            Entry(name: "Planet Money", url: "https://feeds.npr.org/510289/podcast.xml", note: "NPR 经济播客"),
            Entry(name: "The Daily", url: "https://feeds.simplecast.com/54nAGcIl", note: "纽约时报每日新闻"),
            Entry(name: "99% Invisible", url: "https://feeds.simplecast.com/BqbsxVfO", note: "设计与城市"),
            Entry(name: "Lex Fridman Podcast", url: "https://lexfridman.com/feed/podcast/", note: "长访谈"),
        ]),
    ]
}

struct CatalogView: View {
    @EnvironmentObject var store: FeedStore
    @State private var added: Set<String> = []

    var body: some View {
        List {
            Section {
                Text("点 + 就会加进对应分组。热榜类订阅在上一页的 RSSHub 快捷订阅里。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(FeedCatalog.categories) { c in
                Section {
                    ForEach(c.entries) { e in
                        let has = added.contains(e.url) || store.sources.contains { $0.url == e.url }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name)
                                Text(e.note).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                store.addSource(name: e.name, url: e.url, group: c.name)
                                added.insert(e.url)
                            } label: {
                                Image(systemName: has ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.title3)
                                    .foregroundStyle(has ? Color.green : Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(has)
                        }
                    }
                } header: {
                    Label(c.name, systemImage: c.icon)
                }
            }
        }
        .navigationTitle("推荐订阅")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { if !added.isEmpty { Task { await store.refresh() } } }
    }
}
