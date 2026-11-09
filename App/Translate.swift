import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

enum ArticleLanguage {
    /// True when the text is mostly not Chinese, so offering translation makes sense.
    static func needsTranslation(_ text: String, target: String = "zh-Hans") -> Bool {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(1500)))
        guard let lang = r.dominantLanguage, lang != .undetermined else { return false }
        if target.hasPrefix("zh") { return lang.rawValue != target }
        return !lang.rawValue.hasPrefix(String(target.prefix(2)))
    }
    static var available: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }
}

extension HTMLBlock {
    var plainText: String? {
        switch self {
        case .heading(_, let t), .paragraph(let t), .quote(let t), .bullet(_, let t): return String(t.characters)
        default: return nil
        }
    }
    func replacingText(_ s: String) -> HTMLBlock {
        switch self {
        case .heading(let l, let t):
            _ = t; var a = AttributedString(s); a.font = l <= 2 ? .title2.bold() : .title3.bold(); return .heading(l, a)
        case .paragraph: return .paragraph(AttributedString(s))
        case .quote: return .quote(AttributedString(s))
        case .bullet(let m, _): return .bullet(m, AttributedString(s))
        default: return self
        }
    }
}

/// Translates the given texts each time `request` goes up: with AI when set up, otherwise
/// Apple's on-device Translation (iOS 18+). `onResult` gets the texts, or nil and an error message.
struct TranslateTask: ViewModifier {
    let request: Int
    let texts: [String]
    let target: TargetLanguage
    let onResult: ([String]?, String?) -> Void

    func body(content: Content) -> some View {
        systemPart(content)
            .onChange(of: request) { r in
                guard r > 0, TranslatePrefs.effectiveEngine == .ai else { return }
                let t = texts, lang = target
                Task {
                    do {
                        let out = try await AITranslator.translate(t, to: lang)
                        await MainActor.run { onResult(out, nil) }
                    } catch {
                        await MainActor.run { onResult(nil, "AI 翻译失败：\(error.localizedDescription)") }
                    }
                }
            }
    }

    @ViewBuilder private func systemPart(_ content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            content.modifier(TranslateTask18(request: request, texts: texts, target: target, onResult: onResult))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct TranslateTask18: ViewModifier {
    let request: Int
    let texts: [String]
    let target: TargetLanguage
    let onResult: ([String]?, String?) -> Void
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { r in
                guard r > 0, TranslatePrefs.effectiveEngine == .system else { return }
                let lang = Locale.Language(identifier: target.id)
                if config != nil, config?.target == lang {
                    config?.invalidate()
                } else {
                    config = TranslationSession.Configuration(source: nil, target: lang)
                }
            }
            .translationTask(config) { session in
                guard request > 0, !texts.isEmpty else { return }
                let reqs = texts.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                do {
                    let res = try await session.translations(from: reqs)
                    var out = texts
                    for r in res {
                        if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
                    }
                    await MainActor.run { onResult(out, nil) }
                } catch {
                    await MainActor.run { onResult(nil, "请在「设置 > 阅读翻译 > 下载源语言」下载这篇文章的语言后再试，或改用 AI 翻译。") }
                }
            }
    }
}
#endif
