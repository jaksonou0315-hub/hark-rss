import SwiftUI
import WebKit
import SafariServices
import AVKit

struct ArticleView: View {
    let item: FeedItem
    @EnvironmentObject var store: FeedStore
    @State private var fullText: String?
    @State private var loadingFull = false
    @State private var fullError = false
    @State private var safari: SafariTarget?
    @State private var showVideo = false

    struct SafariTarget: Identifiable { let id = UUID(); let url: URL; let reader: Bool }

    private var bodyHTML: String { fullText ?? (item.content.isEmpty ? item.summary : item.content) }
    private var link: URL? { item.link.isEmpty ? nil : URL(string: item.link) }

    var body: some View {
        ZStack(alignment: .bottom) {
            AuroraBackground().opacity(0.45)
            HTMLView(html: ArticleHTML.page(item, body: bodyHTML), baseURL: link)
                .ignoresSafeArea(edges: .bottom)
            actionBar
        }
        .navigationTitle(item.source)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.markRead(item)
            if let c = store.fullText[item.id] { fullText = c }
        }
        .sheet(item: $safari) { t in SafariView(url: t.url, reader: t.reader).ignoresSafeArea() }
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
                    if link != nil {
                        if loadingFull {
                            ProgressView().frame(width: 26, height: 26)
                        } else {
                            barButton(fullText == nil ? "doc.text.magnifyingglass" : "doc.plaintext") { Task { await toggleFull() } }
                        }
                        barButton("eyeglasses") { if let u = link { safari = SafariTarget(url: u, reader: true) } }
                        if let u = link {
                            ShareLink(item: u) { Image(systemName: "square.and.arrow.up").font(.title3) }
                                .buttonStyle(.plain)
                        }
                        barButton("safari") { if let u = link { UIApplication.shared.open(u) } }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .glass(in: Capsule(), interactive: true)
            }
        }
        .padding(.bottom, 10)
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

enum ArticleHTML {
    static func page(_ item: FeedItem, body: String) -> String {
        let date = item.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        let meta = [item.author, item.source, date].filter { !$0.isEmpty }.joined(separator: " · ")
        let content = body.contains("<") ? body : body.escapedHTML.replacingOccurrences(of: "\n", with: "<br>")
        let tags = item.categories.prefix(6).map { "<span class=\"tag\">\($0.escapedHTML)</span>" }.joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        :root{color-scheme:light dark}
        body{font-family:-apple-system,system-ui,"PingFang SC";font-size:17px;line-height:1.7;margin:0;padding:18px 20px 150px;background:transparent;color:#1c1c1e;word-wrap:break-word}
        h1{font-size:26px;line-height:1.3;margin:6px 0 10px;font-weight:700}
        .meta{color:#8e8e93;font-size:13px;margin-bottom:8px}
        .tag{display:inline-block;font-size:12px;padding:2px 9px;margin:0 6px 6px 0;border-radius:999px;background:rgba(127,127,127,.16)}
        .tags{margin-bottom:16px}
        img,video,iframe{max-width:100%;height:auto;border-radius:16px}
        figure{margin:16px 0}
        pre{overflow-x:auto;background:rgba(127,127,127,.12);padding:12px;border-radius:14px;font-size:14px}
        blockquote{margin:0;padding-left:14px;border-left:3px solid rgba(127,127,127,.4);color:#6e6e73}
        a{color:#0a84ff;text-decoration:none}
        @media (prefers-color-scheme:dark){body{color:#f2f2f7}a{color:#64d2ff}blockquote{color:#aeaeb2}}
        </style></head><body>
        <h1>\(item.title.escapedHTML)</h1><div class="meta">\(meta.escapedHTML)</div><div class="tags">\(tags)</div>
        \(content)
        </body></html>
        """
    }
}

struct HTMLView: UIViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.navigationDelegate = context.coordinator
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {
        if context.coordinator.last != html {
            context.coordinator.last = html
            w.loadHTMLString(html, baseURL: baseURL)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var last = ""
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let u = navigationAction.request.url {
                _ = await UIApplication.shared.open(u)
                return .cancel
            }
            return .allow
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var reader = false
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let c = SFSafariViewController.Configuration()
        c.entersReaderIfAvailable = reader
        return SFSafariViewController(url: url, configuration: c)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
