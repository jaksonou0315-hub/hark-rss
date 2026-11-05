import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

enum ArticleLanguage {
    /// True when the text is mostly not Chinese, so offering translation makes sense.
    static func needsTranslation(_ text: String) -> Bool {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(1500)))
        guard let lang = r.dominantLanguage else { return false }
        return !(lang == .simplifiedChinese || lang == .traditionalChinese)
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

/// Runs Apple's on-device Translation (iOS 18+) over the given texts when `active` turns on.
struct TranslateTask: ViewModifier {
    @Binding var active: Bool
    let texts: [String]
    let onResult: ([String]?) -> Void

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            content.modifier(TranslateTask18(active: $active, texts: texts, onResult: onResult))
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
    @Binding var active: Bool
    let texts: [String]
    let onResult: ([String]?) -> Void
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { on in
                guard on else { return }
                if config == nil {
                    config = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: "zh-Hans"))
                } else {
                    config?.invalidate()
                }
            }
            .translationTask(config) { session in
                guard active, !texts.isEmpty else { return }
                let reqs = texts.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                do {
                    let res = try await session.translations(from: reqs)
                    var out = texts
                    for r in res {
                        if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
                    }
                    await MainActor.run { onResult(out) }
                } catch {
                    await MainActor.run { onResult(nil) }
                }
            }
    }
}
#endif
