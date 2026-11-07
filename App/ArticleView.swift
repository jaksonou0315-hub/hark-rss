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
    @State private var anchor: Int?
    @State private var resumed = false
    @State private var showReader = false
    @State private var summary: String?
    @State private var summarizing = false
    @State private var summaryFailed = false
    @ObservedObject private var speaker = Speaker.shared
    @AppStorage("readerSize") private var readerSize = 2
    @AppStorage("autoFullText") private var autoFullText = true
    @AppStorage("readerSpacing") private var readerSpacing = 6.0
    @AppStorage("readerSerif") private var readerSerif = false
    @AppStorage("readerTheme") private var readerThemeRaw = ReaderTheme.auto.rawValue
    private var theme: ReaderTheme { ReaderTheme(rawValue: readerThemeRaw) ?? .auto }
    private var shownBlocks: [HTMLBlock] { showingTranslation ? (translated ?? blocks) : blocks }

    private var translateTexts: [String] { [item.title] + blocks.compactMap(\.plainText) }
    private var showingTranslation: Bool { translateOn && translated != nil }
    @Environment(\.openURL) private var openURL

    private var originalHTML: String { item.content.isEmpty ? item.summary : item.content }
    private var bodyHTML: String { fullText ?? originalHTML }

    /// Feeds that only carry a teaser get the whole article fetched on open.
    /// Video posts (B站 etc.) keep their own content, since their page has no article to extract.
    private var wantsAutoFull: Bool {
        guard autoFullText, fullText == nil, link != nil, !item.isVideo else { return false }
        let lower = originalHTML.lowercased()
        if lower.contains("<video") || lower.contains("<iframe") || lower.contains("<embed") { return false }
        return originalHTML.strippingHTML.count < 600
    }
    private var link: URL? { item.link.isEmpty ? nil : URL(string: item.link) }

    var body: some View {
        ZStack(alignment: .bottom) {
            ReaderBackground(theme: theme)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    HTMLContentView(blocks: shownBlocks, serif: readerSerif, lineSpacing: CGFloat(readerSpacing))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 120)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .dynamicTypeSize(ReaderPrefs.size(readerSize))
            }
            .scrollPosition(id: $anchor, anchor: .top)
            VStack(spacing: 10) {
                MiniPlayerBar().padding(.horizontal, 14)
                actionBar.sheet(isPresented: $showReader) { ReaderSettingsSheet() }
            }
        }
        .modifier(ReaderScheme(theme: theme))
        .navigationTitle(item.source)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { TabBarState.shared.hidden = false }
        .onAppear {
            TabBarState.shared.hidden = true
            store.markRead(item)
            if let c = store.fullText[item.id] { fullText = c }
            else if wantsAutoFull { Task { await loadFull(silent: true) } }
        }
        .task(id: bodyHTML) {
            let html = bodyHTML, base = link, original = originalHTML, isFull = fullText != nil
            var parsed = await Task.detached(priority: .userInitiated) { HTMLParser.parse(html, base: base) }.value
            if isFull {
                // Keep the feed's own videos when the fetched page dropped them.
                let own = await Task.detached(priority: .userInitiated) { HTMLParser.parse(original, base: base) }.value
                let have = Set(parsed.filter(\.isPlayable).map(\.id))
                let missing = own.filter { $0.isPlayable && !have.contains($0.id) }
                parsed = missing + parsed
            }
            if item.isVideo, let u = URL(string: item.enclosureURL), !parsed.contains(where: { $0.id == "v\(u.absoluteString)" }) {
                parsed.insert(.video(u, item.imageURL.isEmpty ? nil : URL(string: item.imageURL)), at: 0)
            }
            blocks = parsed
            translated = nil; translatedTitle = nil
            if translateOn { translateOn = false }
            let sample = ([item.title] + blocks.compactMap(\.plainText)).joined(separator: " ")
            canTranslate = ArticleLanguage.available && ArticleLanguage.needsTranslation(sample)
            if !resumed, let p = ReadingProgress.position(item.id), p > 1, p < blocks.count {
                resumed = true
                try? await Task.sleep(nanoseconds: 350_000_000)
                anchor = p
            }
        }
        .onChange(of: anchor) { v in
            guard let v, !blocks.isEmpty else { return }
            if v >= blocks.count - 2 { ReadingProgress.clear(item.id) } else if v > 1 { ReadingProgress.save(item.id, v) }
        }
        .alert("摘要没有生成", isPresented: $summaryFailed) { Button("好", role: .cancel) {} } message: { Text("本机模型暂时不可用，稍后再试。") }
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
                HStack(spacing: 20) {
                    barButton(store.isStarred(item) ? "star.fill" : "star") { store.toggleStar(item) }
                    barButton(store.isLater(item) ? "clock.fill" : "clock") { store.toggleLater(item) }
                    if canTranslate {
                        barButton(translateOn ? "character.bubble.fill" : "character.bubble") {
                            if translateOn { translateOn = false } else { translateOn = true }
                        }
                    }
                    barButton(speakIcon) { speak() }
                    if link != nil {
                        if loadingFull {
                            ProgressView().frame(width: 26, height: 26)
                        } else {
                            barButton(fullText == nil ? "doc.text.magnifyingglass" : "doc.plaintext") { Task { await toggleFull() } }
                        }
                    }
                    Menu {
                        Button { showReader = true } label: { Label("阅读设置", systemImage: "textformat.size") }
                        if AISummary.available {
                            Button { Task { await summarize() } } label: { Label("AI 摘要", systemImage: "sparkles") }
                        }
                        if let u = link {
                            ShareLink(item: u) { Label("分享", systemImage: "square.and.arrow.up") }
                            Button { openURL(u) } label: { Label("在浏览器打开", systemImage: "safari") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
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
            if summarizing || summary != nil {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    if let summary {
                        Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("正在生成摘要…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: .purple.opacity(0.15))
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

    private var speakIcon: String {
        guard speaker.item?.id == item.id else { return "speaker.wave.2" }
        return speaker.isSpeaking ? "pause.circle" : "play.circle"
    }

    private func speak() {
        if speaker.item?.id == item.id { speaker.toggle(); return }
        let title = showingTranslation ? (translatedTitle ?? item.title) : item.title
        let text = ([title] + shownBlocks.compactMap(\.plainText)).joined(separator: "\n")
        speaker.speak(item, text: text)
    }

    private func summarize() async {
        guard summary == nil, !summarizing else { return }
        summarizing = true
        let text = blocks.compactMap(\.plainText).joined(separator: "\n")
        do { summary = try await AISummary.summarize(title: item.title, text: text) } catch { summaryFailed = true }
        summarizing = false
    }

    private func toggleFull() async {
        if fullText != nil { fullText = nil; return }
        await loadFull(silent: false)
    }

    /// Fetches the full article. Silent loads (on open) fail quietly and keep the feed's text.
    private func loadFull(silent: Bool) async {
        guard !loadingFull else { return }
        loadingFull = true
        do {
            let t = try await FullText.extract(from: item.link)
            // Only swap in what is actually longer than the teaser.
            if !silent || t.strippingHTML.count > originalHTML.strippingHTML.count + 80 {
                store.fullText[item.id] = t
                fullText = t
            }
        } catch {
            if !silent { fullError = true }
        }
        loadingFull = false
    }
}

