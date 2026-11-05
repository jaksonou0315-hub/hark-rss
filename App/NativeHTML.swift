import SwiftUI

/// A small HTML → SwiftUI renderer for feed content. No WebKit.
enum HTMLBlock: Identifiable {
    case heading(Int, AttributedString)
    case paragraph(AttributedString)
    case quote(AttributedString)
    case code(String)
    case bullet(String, AttributedString)
    case image(URL)
    case media(URL, String)
    case rule

    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l)\(String(t.characters.prefix(40)))\(t.characters.count)"
        case .paragraph(let t): return "p\(String(t.characters.prefix(40)))\(t.characters.count)"
        case .quote(let t): return "q\(String(t.characters.prefix(40)))"
        case .code(let s): return "c\(s.prefix(40))\(s.count)"
        case .bullet(let m, let t): return "b\(m)\(String(t.characters.prefix(40)))"
        case .image(let u): return "i\(u.absoluteString)"
        case .media(let u, _): return "m\(u.absoluteString)"
        case .rule: return "r\(UUID().uuidString)"
        }
    }
}

enum HTMLParser {
    private static let named: [String: String] = [
        "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        "&hellip;": "…", "&mdash;": "—", "&ndash;": "–", "&lsquo;": "‘", "&rsquo;": "’",
        "&ldquo;": "“", "&rdquo;": "”", "&copy;": "©", "&reg;": "®", "&middot;": "·", "&amp;": "&"
    ]
    static func decode(_ s: String) -> String {
        var s = s.decodingNumericEntities
        for (k, v) in named where s.contains(k) { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }

    private static let blockTags: Set<String> = ["p", "div", "section", "article", "header", "footer", "figure",
                                                 "figcaption", "table", "tr", "ul", "ol", "dl", "dd", "dt", "main", "aside"]
    private static let skipTags: Set<String> = ["script", "style", "noscript", "svg", "head", "title", "form", "button"]

    static func parse(_ html: String, base: URL?) -> [HTMLBlock] {
        // Plain text content: split into paragraphs.
        if !html.contains("<") {
            return decode(html).components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { .paragraph(AttributedString($0)) }
        }

        var blocks: [HTMLBlock] = []
        var buf = AttributedString()
        var bold = 0, italic = 0, mono = 0, skip = 0
        var links: [URL?] = []
        var heading = 0, quote = 0, pre = 0
        var listStack: [(ordered: Bool, n: Int)] = []
        var bulletMark: String?
        var preText = ""

        func resolve(_ s: String) -> URL? {
            let s = decode(s).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("data:") else { return nil }
            if s.hasPrefix("//") { return URL(string: "https:" + s) }
            return URL(string: s, relativeTo: base)?.absoluteURL
        }
        func attr(_ attrs: String, _ name: String) -> String? {
            let p = "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                  let m = re.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) else { return nil }
            for g in 2...4 { if let r = Range(m.range(at: g), in: attrs) { return String(attrs[r]) } }
            return nil
        }
        func flush() {
            // trim leading/trailing whitespace of the run
            let text = String(buf.characters)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { buf = AttributedString(); bulletMark = nil }
            guard !trimmed.isEmpty else { return }
            var out = buf
            if let lead = text.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) {
                let n = text.distance(from: text.startIndex, to: lead)
                if n > 0 { out.removeSubrange(out.startIndex..<out.index(out.startIndex, offsetByCharacters: n)) }
            }
            let t2 = String(out.characters)
            if let last = t2.lastIndex(where: { !$0.isWhitespace && !$0.isNewline }) {
                let n = t2.distance(from: last, to: t2.endIndex) - 1
                if n > 0 { out.removeSubrange(out.index(out.endIndex, offsetByCharacters: -n)..<out.endIndex) }
            }
            if heading > 0 { blocks.append(.heading(heading, out)) }
            else if let m = bulletMark { blocks.append(.bullet(m, out)) }
            else if quote > 0 { blocks.append(.quote(out)) }
            else { blocks.append(.paragraph(out)) }
        }
        func append(_ raw: String) {
            if pre > 0 { preText += decode(raw); return }
            var t = decode(raw).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if buf.characters.last == " " || buf.characters.last == "\n" || buf.characters.isEmpty, t.hasPrefix(" ") { t.removeFirst() }
            guard !t.isEmpty else { return }
            var a = AttributedString(t)
            // Body text keeps no font of its own, so the reader's size and serif settings apply.
            if heading > 0 { a.font = heading <= 2 ? .title2.bold() : .title3.bold() }
            else if mono > 0 { a.font = .system(.callout, design: .monospaced) }
            var intent: InlinePresentationIntent = []
            if bold > 0 && heading == 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if !intent.isEmpty { a.inlinePresentationIntent = intent }
            if let l = links.last, let u = l { a.link = u; a.foregroundColor = Color.accentColor }
            if mono > 0 { a.backgroundColor = Color.gray.opacity(0.15) }
            buf += a
        }

        let re = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>|([^<]+)|<", options: [])
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 4).location != NSNotFound {
                if skip == 0 { append(ns.substring(with: m.range(at: 4))) }
                continue
            }
            guard m.range(at: 2).location != NSNotFound else { continue }
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let tag = ns.substring(with: m.range(at: 2)).lowercased()
            let attrs = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""

            if skipTags.contains(tag) {
                if attrs.hasSuffix("/") { continue }
                skip += closing ? -1 : 1; skip = max(skip, 0); continue
            }
            if skip > 0 { continue }

            switch tag {
            case "b", "strong": bold += closing ? -1 : 1
            case "i", "em", "cite": italic += closing ? -1 : 1
            case "code", "kbd", "tt": if pre == 0 { mono += closing ? -1 : 1 }
            case "a":
                if closing { _ = links.popLast() } else { links.append(attr(attrs, "href").flatMap(resolve)) }
            case "br": if pre > 0 { preText += "\n" } else { buf += AttributedString("\n") }
            case "hr": flush(); blocks.append(.rule)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush(); heading = closing ? 0 : Int(tag.dropFirst()) ?? 3
            case "blockquote": flush(); quote += closing ? -1 : 1
            case "pre":
                flush()
                if closing {
                    pre = max(pre - 1, 0)
                    let t = preText.trimmingCharacters(in: .newlines)
                    if !t.isEmpty { blocks.append(.code(t)) }
                    preText = ""
                } else { pre += 1 }
            case "ul", "ol":
                flush()
                if closing { _ = listStack.popLast() } else { listStack.append((tag == "ol", 0)) }
            case "li":
                flush()
                if !closing {
                    if var top = listStack.popLast() {
                        top.n += 1; listStack.append(top)
                        bulletMark = top.ordered ? "\(top.n)." : "•"
                    } else { bulletMark = "•" }
                }
            case "img":
                if !closing, let u = (attr(attrs, "data-src") ?? attr(attrs, "src")).flatMap(resolve) {
                    flush(); blocks.append(.image(u))
                }
            case "video", "audio", "iframe", "source", "embed":
                if !closing, let u = attr(attrs, "src").flatMap(resolve) {
                    flush(); blocks.append(.media(u, tag == "audio" ? "播放音频" : "播放视频"))
                }
            default:
                if blockTags.contains(tag) { let keep = bulletMark; flush(); if !closing { bulletMark = keep } }
            }
        }
        flush()
        // Drop duplicate consecutive images
        var out: [HTMLBlock] = []
        for b in blocks {
            if case .image(let u) = b, case .image(let p)? = out.last, p == u { continue }
            out.append(b)
        }
        return out
    }
}

/// Renders parsed blocks natively.
struct HTMLContentView: View {
    let blocks: [HTMLBlock]
    var serif: Bool
    var lineSpacing: CGFloat
    @Environment(\.openURL) private var openURL

    init(blocks: [HTMLBlock], serif: Bool = false, lineSpacing: CGFloat = 6) {
        self.blocks = blocks
        self.serif = serif
        self.lineSpacing = lineSpacing
    }

    private var bodyFont: Font { .system(.body, design: serif ? .serif : .default) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .scrollTargetLayout()
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func block(_ b: HTMLBlock) -> some View {
        switch b {
        case .heading(_, let t):
            Text(t).padding(.top, 6)
        case .paragraph(let t):
            Text(t).font(bodyFont).lineSpacing(lineSpacing).fixedSize(horizontal: false, vertical: true)
        case .quote(let t):
            HStack(alignment: .top, spacing: 12) {
                Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                Text(t).font(bodyFont).foregroundStyle(.secondary).lineSpacing(lineSpacing - 1)
            }
            .padding(14)
            .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(.footnote, design: .monospaced)).padding(14)
            }
            .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .bullet(let m, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m).foregroundStyle(.secondary).monospacedDigit()
                Text(t).font(bodyFont).lineSpacing(lineSpacing - 1)
            }
            .padding(.leading, 4)
        case .image(let u):
            AsyncImage(url: u, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                case .failure:
                    EmptyView()
                default:
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.gray.opacity(0.12)).frame(height: 180)
                        .overlay(ProgressView())
                }
            }
            .frame(maxWidth: .infinity)
        case .media(let u, let label):
            Button { openURL(u) } label: {
                Label(label, systemImage: "play.circle.fill").font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glass(in: Capsule(), interactive: true)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}
