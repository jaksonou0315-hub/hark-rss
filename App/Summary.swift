import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One-line summaries with Apple's on-device model (iOS 26, Apple Intelligence devices only).
enum AISummary {
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func summarize(title: String, text: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: "你是新闻编辑，只用简体中文回答。")
            let prompt = "用一到两句话概括下面这篇文章的要点，直接写结论，不要开场白。\n标题：\(title)\n正文：\(String(text.prefix(3000)))"
            let r = try await session.respond(to: prompt)
            return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw URLError(.unsupportedURL)
    }
}
