import SwiftUI
import Security
#if canImport(Translation)
import Translation
#endif

// MARK: - Preferences

enum TranslateEngine: String, CaseIterable, Identifiable {
    case system, ai
    var id: String { rawValue }
    var label: String { self == .system ? "系统翻译（本机）" : "AI 翻译" }
}

struct TargetLanguage: Identifiable, Hashable {
    let id: String      // BCP-47, e.g. zh-Hans
    let name: String    // shown to the user
    let english: String // used in the AI prompt

    static let all: [TargetLanguage] = [
        .init(id: "zh-Hans", name: "简体中文", english: "Simplified Chinese"),
        .init(id: "zh-Hant", name: "繁體中文", english: "Traditional Chinese"),
        .init(id: "en", name: "English", english: "English"),
        .init(id: "ja", name: "日本語", english: "Japanese"),
        .init(id: "ko", name: "한국어", english: "Korean"),
        .init(id: "fr", name: "Français", english: "French"),
        .init(id: "de", name: "Deutsch", english: "German"),
        .init(id: "es", name: "Español", english: "Spanish"),
        .init(id: "it", name: "Italiano", english: "Italian"),
        .init(id: "pt-BR", name: "Português", english: "Portuguese"),
        .init(id: "ru", name: "Русский", english: "Russian"),
        .init(id: "ar", name: "العربية", english: "Arabic"),
        .init(id: "th", name: "ไทย", english: "Thai"),
        .init(id: "vi", name: "Tiếng Việt", english: "Vietnamese"),
        .init(id: "id", name: "Bahasa Indonesia", english: "Indonesian"),
        .init(id: "tr", name: "Türkçe", english: "Turkish"),
    ]
    static func find(_ id: String) -> TargetLanguage { all.first { $0.id == id } ?? all[0] }
}

struct AIProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let defaultModel: String

    static let all: [AIProvider] = [
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat"),
        .init(id: "qwen", name: "通义千问（阿里云百炼）", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen-plus"),
        .init(id: "glm", name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4-flash"),
        .init(id: "kimi", name: "Kimi（月之暗面）", baseURL: "https://api.moonshot.cn/v1", defaultModel: "moonshot-v1-8k"),
        .init(id: "doubao", name: "豆包（火山方舟）", baseURL: "https://ark.cn-beijing.volces.com/api/v3", defaultModel: ""),
        .init(id: "siliconflow", name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", defaultModel: "Qwen/Qwen2.5-7B-Instruct"),
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini"),
        .init(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-2.0-flash"),
        .init(id: "claude", name: "Anthropic Claude", baseURL: "https://api.anthropic.com/v1", defaultModel: "claude-3-5-haiku-latest"),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-4o-mini"),
        .init(id: "ollama", name: "Ollama（局域网）", baseURL: "http://192.168.1.2:11434/v1", defaultModel: "qwen2.5"),
        .init(id: "custom", name: "自定义（OpenAI 兼容）", baseURL: "", defaultModel: ""),
    ]
    static func find(_ id: String) -> AIProvider { all.first { $0.id == id } ?? all.last! }
}

enum TranslatePrefs {
    static var engine: TranslateEngine {
        TranslateEngine(rawValue: UserDefaults.standard.string(forKey: "translateEngine") ?? "") ?? .system
    }
    static var target: TargetLanguage {
        TargetLanguage.find(UserDefaults.standard.string(forKey: "translateTarget") ?? "zh-Hans")
    }
    static var baseURL: String { UserDefaults.standard.string(forKey: "aiBaseURL") ?? "" }
    static var model: String { UserDefaults.standard.string(forKey: "aiModel") ?? "" }
    static var apiKey: String { Keychain.get("aiAPIKey") ?? "" }
    static var aiReady: Bool { !baseURL.isEmpty && !model.isEmpty }
    /// AI when chosen and set up, system otherwise.
    static var effectiveEngine: TranslateEngine {
        if engine == .ai, aiReady { return .ai }
        return ArticleLanguage.available ? .system : (aiReady ? .ai : .system)
    }
    static var canTranslate: Bool { ArticleLanguage.available || aiReady }
}

enum Keychain {
    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "com.ouyanghong.harkrss",
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "com.ouyanghong.harkrss",
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - AI translation (OpenAI-compatible chat completions)

enum AITranslateError: LocalizedError {
    case notConfigured, http(Int, String), badReply
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没填写 AI 接口地址和模型。"
        case .http(let c, let m): return "接口返回 \(c)：\(m)"
        case .badReply: return "模型返回的内容无法解析。"
        }
    }
}

enum AITranslator {
    private static func endpoint(_ path: String, base: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/chat/completions") { b = String(b.dropLast("/chat/completions".count)) }
        return URL(string: b + path)
    }

    private static func request(_ url: URL, key: String, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 90)
        if !key.isEmpty {
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let body {
            r.httpMethod = "POST"
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private static func errText(_ d: Data) -> String {
        if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let e = j["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = j["message"] as? String { return m }
        }
        return String(String(data: d, encoding: .utf8)?.prefix(160) ?? "")
    }

    /// Lists the models the endpoint offers (GET /models).
    static func models(base: String, key: String) async throws -> [String] {
        guard let u = endpoint("/models", base: base) else { throw AITranslateError.notConfigured }
        let (d, resp) = try await URLSession.shared.data(for: request(u, key: key))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AITranslateError.http(code, errText(d)) }
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        let list = (j?["data"] as? [[String: Any]]) ?? (j?["models"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
    }

    static func chat(_ system: String, _ user: String, base: String, key: String, model: String) async throws -> String {
        guard let u = endpoint("/chat/completions", base: base), !model.isEmpty else { throw AITranslateError.notConfigured }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: request(u, key: key, body: data))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AITranslateError.http(code, errText(d)) }
        guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choices = j["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else { throw AITranslateError.badReply }
        return text
    }

    private static func prompt(_ lang: TargetLanguage) -> String {
        "You are a professional news translator. Translate every string in the JSON array the user sends into \(lang.english). " +
        "Keep names, numbers and meaning accurate and the tone natural for native readers. " +
        "Reply with ONLY a JSON array of strings, the same length and order as the input, no explanations, no code fences."
    }

    private static func parseArray(_ s: String) -> [String]? {
        guard let a = s.firstIndex(of: "["), let b = s.lastIndex(of: "]"), a < b else { return nil }
        let slice = String(s[a...b])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String]
    }

    private static func runBatch(_ idx: [Int], texts: [String], lang: TargetLanguage, sys: String,
                                 base: String, key: String, model: String) async throws -> [(Int, String)] {
        let input = idx.map { texts[$0] }
        let json = String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8) ?? "[]"
        let reply = try await chat(sys, json, base: base, key: key, model: model)
        if let arr = parseArray(reply), arr.count == input.count {
            return Array(zip(idx, arr))
        }
        // Model ignored the format: translate one by one.
        var res: [(Int, String)] = []
        for i in idx {
            let one = try await chat("Translate the user's text into \(lang.english). Reply with the translation only.",
                                     texts[i], base: base, key: key, model: model)
            res.append((i, one.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return res
    }

    /// Translates texts in batches of about 2,500 characters, three batches at a time.
    static func translate(_ texts: [String], to lang: TargetLanguage) async throws -> [String] {
        let base = TranslatePrefs.baseURL, key = TranslatePrefs.apiKey, model = TranslatePrefs.model
        guard !base.isEmpty, !model.isEmpty else { throw AITranslateError.notConfigured }
        var batches: [[Int]] = [[]]
        var size = 0
        for (i, t) in texts.enumerated() {
            if size + t.count > 2500, !(batches.last!.isEmpty) { batches.append([]); size = 0 }
            batches[batches.count - 1].append(i); size += t.count
        }
        var out = texts
        let sys = prompt(lang)
        var start = 0
        while start < batches.count {
            let chunk = Array(batches[start..<min(start + 3, batches.count)])
            start += 3
            try await withThrowingTaskGroup(of: [(Int, String)].self) { group in
                for idx in chunk {
                    group.addTask { try await runBatch(idx, texts: texts, lang: lang, sys: sys, base: base, key: key, model: model) }
                }
                for try await r in group {
                    for (i, s) in r { out[i] = s }
                }
            }
        }
        return out
    }
}

// MARK: - Settings page

struct TranslateSettingsForm: View {
    @AppStorage("translateEngine") private var engine = TranslateEngine.system.rawValue
    @AppStorage("translateTarget") private var target = "zh-Hans"
    @AppStorage("aiProvider") private var provider = "deepseek"
    @AppStorage("aiBaseURL") private var baseURL = ""
    @AppStorage("aiModel") private var model = ""
    @State private var key = ""
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var testing = false
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                Picker("翻译成", selection: $target) {
                    ForEach(TargetLanguage.all) { Text($0.name).tag($0.id) }
                }
                Picker("翻译方式", selection: $engine) {
                    ForEach(TranslateEngine.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } footer: {
                Text("文章语言和目标语言不同时，文章底栏会出现翻译按钮。长按翻译按钮可以临时换目标语言。")
            }

            if engine == TranslateEngine.system.rawValue {
                Section {
                    if ArticleLanguage.available {
                        #if canImport(Translation)
                        if #available(iOS 18.0, *) {
                            NavigationLink {
                                SystemLanguagesView(target: TargetLanguage.find(target)).navigationTitle("下载源语言")
                            } label: {
                                Label("下载源语言", systemImage: "arrow.down.circle")
                            }
                        }
                        #endif
                    } else {
                        Text("系统翻译需要 iOS 18 或更新版本，请改用 AI 翻译。").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("系统翻译")
                } footer: {
                    Text("苹果本机翻译，免费、离线、不上传内容。每种源语言要先下载一次。")
                }
            } else {
                Section {
                    Picker("服务商", selection: $provider) {
                        ForEach(AIProvider.all) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: provider) { id in
                        let p = AIProvider.find(id)
                        if id != "custom" { baseURL = p.baseURL; model = p.defaultModel }
                        models = []
                    }
                    TextField("接口地址，如 https://api.xxx.com/v1", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { Keychain.set("aiAPIKey", key) }
                        .onChange(of: key) { Keychain.set("aiAPIKey", $0) }
                } header: {
                    Text("AI 服务")
                } footer: {
                    Text("支持所有 OpenAI 兼容接口（/chat/completions）。Key 只存在本机钥匙串里。豆包需要填方舟的接入点 ID 作为模型。")
                }

                Section {
                    TextField("模型名称", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !models.isEmpty {
                        Picker("从列表选择", selection: $model) {
                            if !models.contains(model) { Text(model.isEmpty ? "未选择" : model).tag(model) }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    Button {
                        Task { await loadModels() }
                    } label: {
                        HStack { Text("获取模型列表"); if loadingModels { Spacer(); ProgressView() } }
                    }
                    .disabled(baseURL.isEmpty || loadingModels)
                    Button {
                        Task { await test() }
                    } label: {
                        HStack { Text("测试翻译"); if testing { Spacer(); ProgressView() } }
                    }
                    .disabled(baseURL.isEmpty || model.isEmpty || testing)
                } header: {
                    Text("模型")
                } footer: {
                    if let note { Text(note) }
                }
            }
        }
        .onAppear {
            key = Keychain.get("aiAPIKey") ?? ""
            if baseURL.isEmpty, provider != "custom" {
                let p = AIProvider.find(provider); baseURL = p.baseURL; if model.isEmpty { model = p.defaultModel }
            }
        }
    }

    private func loadModels() async {
        loadingModels = true; defer { loadingModels = false }
        Keychain.set("aiAPIKey", key)
        do {
            models = try await AITranslator.models(base: baseURL, key: key)
            note = models.isEmpty ? "接口没有返回模型，请手动填写模型名称。" : "找到 \(models.count) 个模型。"
        } catch {
            note = "获取失败：\(error.localizedDescription)"
        }
    }

    private func test() async {
        testing = true; defer { testing = false }
        Keychain.set("aiAPIKey", key)
        do {
            let r = try await AITranslator.translate(["Breaking news: the city opened a new subway line today."],
                                                     to: TargetLanguage.find(target))
            note = "成功：\(r.first ?? "")"
        } catch {
            note = "失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - System language downloads (iOS 18+)

#if canImport(Translation)
@available(iOS 18.0, *)
struct SystemLanguagesView: View {
    let target: TargetLanguage
    @State private var langs: [Locale.Language] = []
    @State private var status: [String: LanguageAvailability.Status] = [:]
    @State private var config: TranslationSession.Configuration?
    @State private var loading = true
    @State private var downloading: String?

    private var targetLang: Locale.Language { Locale.Language(identifier: target.id) }

    private func key(_ l: Locale.Language) -> String { l.maximalIdentifier }
    private func name(_ l: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: l.minimalIdentifier) ?? l.minimalIdentifier
    }

    var body: some View {
        List {
            Section {
                if loading { HStack { ProgressView(); Text("正在读取系统支持的语言…") } }
                ForEach(langs, id: \.maximalIdentifier) { l in
                    HStack {
                        Text(name(l))
                        Spacer()
                        switch status[key(l)] {
                        case .installed?:
                            Label("已下载", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                                .font(.caption).foregroundStyle(.green)
                        case .supported?:
                            if downloading == key(l) {
                                ProgressView()
                            } else {
                                Button("下载") { download(l) }.buttonStyle(.bordered).controlSize(.small)
                            }
                        default:
                            Text("不支持").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("翻译成 \(target.name)")
            } footer: {
                Text("下载的是「源语言 → \(target.name)」所需的离线语言包。要删除已下载的语言，去系统「设置 > App > 翻译 > 已下载的语言」。")
            }
        }
        .task { await refresh() }
        .translationTask(config) { session in
            do { try await session.prepareTranslation() } catch {}
            await MainActor.run { downloading = nil }
            await refresh()
        }
    }

    private func download(_ l: Locale.Language) {
        downloading = key(l)
        config = TranslationSession.Configuration(source: l, target: targetLang)
    }

    private func refresh() async {
        let a = LanguageAvailability()
        let all = await a.supportedLanguages
        var s: [String: LanguageAvailability.Status] = [:]
        var list: [Locale.Language] = []
        for l in all where l.minimalIdentifier != targetLang.minimalIdentifier {
            s[key(l)] = await a.status(from: l, to: targetLang)
            list.append(l)
        }
        list.sort { name($0) < name($1) }
        await MainActor.run { langs = list; status = s; loading = false }
    }
}
#endif
