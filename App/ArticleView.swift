import SwiftUI
import AVKit

struct ArticleView: View {
    let item: FeedItem
    @EnvironmentObject var store: FeedStore
    @State private var fullText: String?
    @State private var loadingFull = false
    @State private var fullError = false
    @State private var showVideo = false
    @State private var blocks: [HTMLBlock] = []
    @State private var translateOn = false
    @State private var translatedTitle: String?
    @State private var translated: [HTMLBlock]?
    @State private var translateFailed = false
    @State private var canTranslate = false

    private var translateTexts: [String] { [item.title] + blocks.compactMap(\.plainText) }
    private var showingTranslation: Bool { translateOn && translated != nil }
    @Environment(\.openURL) private var openURL

    private var bodyHTML: String { fullText ?? (item.content.isEmpty ? item.summary : item.content) }
    private var link: URL? { item.link.isEmpty ? nil : URL(string: item.link) }

    var body: some View {
        ZStack(alignment: .bottom) {
            AuroraBackground().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    HTMLContentView(blocks: showingTranslation ? (translated ?? blocks) : blocks)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 120)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 10) {
                MiniPlayerBar().padding(.horizontal, 14)
                actionBar
            }
        }
        .navigationTitle(item.source)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { TabBarState.shared.hidden = false }
        .onAppear {
            TabBarState.shared.hidden = true
            store.markRead(item)
            if let c = store.fullText[item.id] { fullText = c }
        }
        .task(id: bodyHTML) {
            let html = bodyHTML, base = link
            blocks = await Task.detached(priority: .userInitiated) { HTMLParser.parse(html, base: base) }.value
            translated = nil; translatedTitle = nil
            if translateOn { translateOn = false }
            let sample = ([item.title] + blocks.compactMap(\.plainText)).joined(separator: " ")
            canTranslate = ArticleLanguage.available && ArticleLanguage.needsTranslation(sample)
        }
        .modifier(TranslateTask(active: $translateOn, texts: translateTexts) { out in
            guard let out, !out.isEmpty else { translateOn = false; translateFailed = true; return }
            translatedTitle = out[0]
            var rest = out.dropFirst().makeIterator()
            translated = blocks.map { b in
                if b.plainText != nil, let t = rest.next() { return b.replacingText(t) }
                return b
            }
        })
        .alert("翻译没有完成", isPresented: $translateFailed) { Button("好", role: .cancel) {} } message: { Text("请在系统「设置 > 通用 > 语言与地区 > 翻译语言」下载中文和原文语言后再试。") }
        .sheet(isPresented: $showVideo) { VideoPlayer(player: Player.shared.avPlayer).ignoresSafeArea() }
        .alert("抓取全文失败", isPresented: $fullError) { Button("好", role: .cancel) {} } message: { Text("可以试试阅读模式或打开原文。") }
    }

    private var actionBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if item.hasMedia {
                    Button {
                        Player.shared.play(item)
                        if item.isVideo { showVideo = true }
                    } label: {
                        Image(systemName: item.isVideo ? "play.rectangle.fill" : "play.fill").font(.title3).frame(width: 30, height: 30)
                    }
                    .glassButton(prominent: true)
                }
                HStack(spacing: 22) {
                    barButton(store.isStarred(item) ? "star.fill" : "star") { store.toggleStar(item) }
                    barButton(store.isLater(item) ? "clock.fill" : "clock") { store.toggleLater(item) }
                    if canTranslate {
                        barButton(translateOn ? "character.bubble.fill" : "character.bubble") {
                            if translateOn { translateOn = false } else { translateOn = true }
                        }
                    }
                    if link != nil {
                        if loadingFull {
                            ProgressView().frame(width: 26, height: 26)
                        } else {
                            barButton(fullText == nil ? "doc.text.magnifyingglass" : "doc.plaintext") { Task { await toggleFull() } }
                        }
                        if let u = link {
                            ShareLink(item: u) { Image(systemName: "square.and.arrow.up").font(.title3) }
                                .buttonStyle(.plain)
                        }
                        barButton("safari") { if let u = link { openURL(u) } }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .glass(in: Capsule(), interactive: true)
            }
        }
        .padding(.bottom, 10)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(showingTranslation ? (translatedTitle ?? item.title) : item.title)
                .font(.system(.title, design: .default).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            let date = item.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            Text([item.author, item.source, date].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary)
            if !item.categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassGroup(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(Array(item.categories.prefix(6)), id: \.self) { c in
                                Text(c).font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .glass(in: Capsule())
                            }
                        }
                    }
                }
            }
            if fullText != nil {
                Label("已显示全文", systemImage: "doc.plaintext").font(.caption).foregroundStyle(.secondary)
            }
            if translateOn {
                HStack(spacing: 6) {
                    if translated == nil { ProgressView().controlSize(.small); Text("正在本机翻译…") }
                    else { Image(systemName: "character.bubble"); Text("已翻译为中文 · 再点一次看原文") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func barButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title3) }
            .buttonStyle(.plain)
            .frame(width: 26, height: 26)
    }

    private func toggleFull() async {
        if fullText != nil { fullText = nil; return }
        loadingFull = true
        do {
            let t = try await FullText.extract(from: item.link)
            store.fullText[item.id] = t
            fullText = t
        } catch {
            fullError = true
        }
        loadingFull = false
    }
}

