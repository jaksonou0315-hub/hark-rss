import SwiftUI

// MARK: - LLM providers for subtitle translation

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case deepseek, qwen, kimi, zhipu, doubao, siliconflow, hunyuan, openai, gemini, claude, grok, openrouter, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .qwen: return "通义千问（阿里百炼）"
        case .kimi: return "Kimi（月之暗面）"
        case .zhipu: return "智谱 GLM"
        case .doubao: return "豆包（火山方舟）"
        case .siliconflow: return "硅基流动"
        case .hunyuan: return "腾讯混元"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .claude: return "Anthropic Claude"
        case .grok: return "xAI Grok"
        case .openrouter: return "OpenRouter"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var defaultBase: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .hunyuan: return "https://api.hunyuan.cloud.tencent.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .claude: return "https://api.anthropic.com/v1"
        case .grok: return "https://api.x.ai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return "http://192.168.1.2:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .qwen: return "qwen-plus"
        case .kimi: return "moonshot-v1-32k"
        case .zhipu: return "glm-4-flash"
        case .doubao: return "doubao-1-5-pro-32k-250115"
        case .siliconflow: return "Qwen/Qwen2.5-7B-Instruct"
        case .hunyuan: return "hunyuan-turbos-latest"
        case .openai: return "gpt-4o-mini"
        case .gemini: return "gemini-2.5-flash"
        case .claude: return "claude-haiku-4-5"
        case .grok: return "grok-3-mini"
        case .openrouter: return "openai/gpt-4o-mini"
        case .custom: return "qwen2.5:7b"
        }
    }

    var keyHint: String {
        switch self {
        case .deepseek: return "platform.deepseek.com › API keys"
        case .qwen: return "bailian.console.aliyun.com › API-KEY"
        case .kimi: return "platform.moonshot.cn › API Key 管理"
        case .zhipu: return "open.bigmodel.cn › API Keys（glm-4-flash 免费）"
        case .doubao: return "console.volcengine.com/ark › API Key；模型填推理接入点 ID 或模型名"
        case .siliconflow: return "cloud.siliconflow.cn › API 密钥（Qwen2.5-7B 免费）"
        case .hunyuan: return "console.cloud.tencent.com/hunyuan › API KEY"
        case .openai: return "platform.openai.com › API keys"
        case .gemini: return "aistudio.google.com › Get API key"
        case .claude: return "console.anthropic.com › API Keys"
        case .grok: return "console.x.ai › API Keys"
        case .openrouter: return "openrouter.ai › Keys"
        case .custom: return "Ollama / LM Studio / One API 等，Key 可留空"
        }
    }
}

final class AITranslateConfig: ObservableObject {
    static let shared = AITranslateConfig()
    private let d = UserDefaults.standard

    @Published var provider: AIProvider { didSet { d.set(provider.rawValue, forKey: "aitr.provider"); reload() } }
    @Published var apiKey: String = "" { didSet { if !loading { Keychain.set(apiKey, for: "aitr.key.\(provider.rawValue)") } } }
    @Published var model: String = "" { didSet { if !loading { d.set(model, forKey: "aitr.model.\(provider.rawValue)") } } }
    @Published var baseURL: String = "" { didSet { if !loading { d.set(baseURL, forKey: "aitr.base.\(provider.rawValue)") } } }
    @Published var batchSize: Int { didSet { d.set(batchSize, forKey: "aitr.batch") } }
    @Published var concurrency: Int { didSet { d.set(concurrency, forKey: "aitr.conc") } }
    @Published var extraPrompt: String { didSet { d.set(extraPrompt, forKey: "aitr.prompt") } }
    private var loading = false

    private init() {
        provider = AIProvider(rawValue: d.string(forKey: "aitr.provider") ?? "") ?? .deepseek
        batchSize = d.object(forKey: "aitr.batch") as? Int ?? 40
        concurrency = d.object(forKey: "aitr.conc") as? Int ?? 3
        extraPrompt = d.string(forKey: "aitr.prompt") ?? ""
        reload()
    }

    private func reload() {
        loading = true
        apiKey = Keychain.get("aitr.key.\(provider.rawValue)") ?? ""
        model = d.string(forKey: "aitr.model.\(provider.rawValue)") ?? provider.defaultModel
        baseURL = d.string(forKey: "aitr.base.\(provider.rawValue)") ?? provider.defaultBase
        loading = false
    }

    var isReady: Bool { (!apiKey.isEmpty || provider == .custom) && !model.isEmpty && URL(string: baseURL) != nil }
}

/// Cumulative token usage per model on this device.
enum AIUsage {
    struct Row: Identifiable { var id: String { model }; let model: String; let input: Int; let output: Int; let calls: Int }
    private static let key = "aitr.usage"
    static func add(model: String, input: Int, output: Int) {
        DispatchQueue.main.async {
            var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]]) ?? [:]
            var r = all[model] ?? [0, 0, 0]
            if r.count < 3 { r = [0, 0, 0] }
            r[0] += input; r[1] += output; r[2] += 1
            all[model] = r
            UserDefaults.standard.set(all, forKey: key)
        }
    }
    static var rows: [Row] {
        let all = (UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]]) ?? [:]
        return all.compactMap { k, v in v.count >= 3 ? Row(model: k, input: v[0], output: v[1], calls: v[2]) : nil }
            .sorted { $0.input + $0.output > $1.input + $1.output }
    }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

enum AITranslator {
    /// GET {base}/models (OpenAI-compatible; Claude uses x-api-key).
    static func listModels() async throws -> [String] {
        let cfg = AITranslateConfig.shared
        let base = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let u = URL(string: base + "/models") else { throw AppError.message("接口地址无效") }
        var req = URLRequest(url: u); req.timeoutInterval = 20
        if cfg.provider == .claude {
            req.setValue(cfg.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !cfg.apiKey.isEmpty {
            req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AppError.message("获取模型失败（\(code)）") }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let arr = (obj?["data"] as? [[String: Any]]) ?? (obj?["models"] as? [[String: Any]]) ?? []
        return arr.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "en": return "English"
        case "ja": return "日本語"
        case "ko": return "한국어"
        default: return code
        }
    }

    /// One chat call.
    static func chat(system: String, user: String) async throws -> String {
        let cfg = AITranslateConfig.shared
        let base = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var req: URLRequest
        var body: [String: Any]
        if cfg.provider == .claude {
            guard let u = URL(string: base + "/messages") else { throw AppError.message("接口地址无效") }
            req = URLRequest(url: u)
            req.setValue(cfg.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": cfg.model, "max_tokens": 8000, "temperature": 0.2, "system": system,
                    "messages": [["role": "user", "content": user]]]
        } else {
            guard let u = URL(string: base + "/chat/completions") else { throw AppError.message("接口地址无效") }
            req = URLRequest(url: u)
            if !cfg.apiKey.isEmpty { req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization") }
            if cfg.provider == .openrouter { req.setValue("HarkPlayer", forHTTPHeaderField: "X-Title") }
            body = ["model": cfg.model, "temperature": 0.2, "stream": false,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? (obj?["message"] as? String)
                ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AppError.message("\(cfg.provider.title) 返回 \(code)：\(msg)")
        }
        if let u = obj?["usage"] as? [String: Any] {
            let inT = (u["prompt_tokens"] as? Int) ?? (u["input_tokens"] as? Int) ?? 0
            let outT = (u["completion_tokens"] as? Int) ?? (u["output_tokens"] as? Int) ?? 0
            AIUsage.add(model: cfg.model, input: inT, output: outT)
        }
        if cfg.provider == .claude {
            let parts = (obj?["content"] as? [[String: Any]]) ?? []
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        let choices = obj?["choices"] as? [[String: Any]]
        let msg = choices?.first?["message"] as? [String: Any]
        if let s = msg?["content"] as? String { return s }
        throw AppError.message("\(cfg.provider.title) 没有返回内容")
    }

    static func test() async -> String {
        do {
            let r = try await chat(system: "You are a translator.", user: "Translate to \(languageName(AppSettings.shared.translateTarget)): Hello, nice to meet you.")
            return "连接成功：" + r.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
        } catch { return error.localizedDescription }
    }

    private static func systemPrompt(target: String) -> String {
        var p = """
        You are a professional film and TV subtitle translator. Translate every subtitle line into \(languageName(target)).
        Rules: keep the meaning, tone and names natural for viewers; keep it concise like real subtitles; do not merge or split lines; \
        do not add notes. Input is a JSON array of strings. Output ONLY a JSON array of translated strings with exactly the same length and order.
        """
        let extra = AITranslateConfig.shared.extraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { p += "\nExtra instructions from the viewer: " + extra }
        return p
    }

    private static func parseArray(_ s: String) -> [String]? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = t.range(of: "["), let b = t.range(of: "]", options: .backwards), a.lowerBound < b.upperBound {
            t = String(t[a.lowerBound..<b.upperBound])
        }
        guard let d = t.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return nil }
        return arr.map { ($0 as? String) ?? "\($0)" }
    }

    /// Translates a batch; if the model returns the wrong number of lines, splits and retries.
    static func translateBatch(_ lines: [String], target: String, context: String) async throws -> [String] {
        let input = String(data: try JSONSerialization.data(withJSONObject: lines), encoding: .utf8) ?? "[]"
        let user = (context.isEmpty ? "" : "Previous lines for context (do not translate): \(context)\n\n") + input
        var lastErr: Error?
        for _ in 0..<2 {
            do {
                let out = try await chat(system: systemPrompt(target: target), user: user)
                if let arr = parseArray(out), arr.count == lines.count { return arr }
            } catch { lastErr = error }
        }
        if let e = lastErr, lines.count <= 1 { throw e }
        if lines.count <= 1 { return lines }
        let mid = lines.count / 2
        let a = try await translateBatch(Array(lines[..<mid]), target: target, context: context)
        let b = try await translateBatch(Array(lines[mid...]), target: target, context: lines[..<mid].suffix(3).joined(separator: " / "))
        return a + b
    }

    static func translateFile(_ url: URL, bilingual: Bool, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> URL {
        let cfg = AITranslateConfig.shared
        guard cfg.isReady else { throw AppError.message("请先在「设置 › AI 翻译」里选择厂商并填写 API Key") }
        let data = try Data(contentsOf: url)
        guard let raw = SubtitleService.decode(data) else { throw AppError.message("无法读取字幕文件") }
        let cues = SubtitleTranslator.parse(raw, ext: url.pathExtension.lowercased())
        guard !cues.isEmpty else { throw AppError.message("字幕里没有可翻译的文本（图形字幕不支持翻译）") }
        let texts = cues.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
        let size = max(5, min(cfg.batchSize, 200))
        let chunks = stride(from: 0, to: texts.count, by: size).map { $0..<min($0 + size, texts.count) }
        let target = AppSettings.shared.translateTarget
        var results = [Int: [String]]()
        var done = 0
        var firstError: Error?
        let conc = max(1, min(cfg.concurrency, 8))
        await progress(0, chunks.count)
        let jobs: [(Int, [String], String)] = chunks.enumerated().map { i, r in
            (i, Array(texts[r]), r.lowerBound > 0 ? texts[max(0, r.lowerBound - 3)..<r.lowerBound].joined(separator: " / ") : "")
        }
        try await withThrowingTaskGroup(of: (Int, [String]?, String?).self) { group in
            var next = 0
            while next < min(conc, jobs.count) {
                let j = jobs[next]; next += 1
                group.addTask {
                    do { return (j.0, try await translateBatch(j.1, target: target, context: j.2), nil) }
                    catch { return (j.0, nil, error.localizedDescription) }
                }
            }
            while let (i, out, err) = try await group.next() {
                if let out { results[i] = out } else if firstError == nil { firstError = AppError.message(err ?? "翻译失败") }
                done += 1
                await progress(done, chunks.count)
                if done == 1, results.isEmpty, let e = firstError { group.cancelAll(); throw e }
                if next < jobs.count {
                    let j = jobs[next]; next += 1
                    group.addTask {
                        do { return (j.0, try await translateBatch(j.1, target: target, context: j.2), nil) }
                        catch { return (j.0, nil, error.localizedDescription) }
                    }
                }
            }
        }
        if results.isEmpty { throw firstError ?? AppError.message("翻译失败") }
        var out = ""
        for (ci, r) in chunks.enumerated() {
            let tr = results[ci]
            for (k, n) in r.enumerated() {
                let c = cues[n]
                let t = tr?[k] ?? c.text
                out += "\(n + 1)\n\(c.start) --> \(c.end)\n\(t)\n"
                if bilingual { out += texts[n] + "\n" }
                out += "\n"
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("ai-\(UUID().uuidString.prefix(8)).srt")
        try out.data(using: .utf8)!.write(to: dst)
        return dst
    }
}

// MARK: - Settings UI

struct AITranslateSettings: View {
    @ObservedObject private var cfg = AITranslateConfig.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var testing = false
    @State private var testResult: String?
    @State private var models: [String] = []
    @State private var fetching = false
    @State private var modelNote: String?

    var body: some View {
        Section {
            Picker("厂商", selection: $cfg.provider) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }
            SecureField(cfg.provider == .custom ? "API Key（可留空）" : "API Key", text: $cfg.apiKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            HStack {
                Text("模型").foregroundStyle(.secondary)
                TextField(cfg.provider.defaultModel, text: $cfg.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing)
                Menu {
                    if models.isEmpty { Text("点「获取模型列表」") }
                    ForEach(models, id: \.self) { m in Button(m) { cfg.model = m } }
                } label: { Image(systemName: "chevron.up.chevron.down") }
            }
            Button {
                fetching = true; modelNote = nil
                Task {
                    do { models = try await AITranslator.listModels(); modelNote = "已获取 \(models.count) 个模型" }
                    catch { modelNote = error.localizedDescription }
                    fetching = false
                }
            } label: { HStack { Text("获取模型列表"); if fetching { Spacer(); ProgressView() } } }
            .disabled(fetching || URL(string: cfg.baseURL) == nil)
            if let n = modelNote { Text(n).font(.footnote).foregroundStyle(.secondary) }
            HStack {
                Text("接口地址").foregroundStyle(.secondary)
                TextField(cfg.provider.defaultBase, text: $cfg.baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .multilineTextAlignment(.trailing).font(.footnote)
            }
            Picker("翻译成", selection: $settings.translateTarget) {
                ForEach(AILanguages.targets, id: \.0) { Text($0.1).tag($0.0) }
            }
            Toggle("保留原文（双语）", isOn: $settings.bilingualSubs)
            Stepper("每次请求 \(cfg.batchSize) 句", value: $cfg.batchSize, in: 10...120, step: 10)
            Stepper("同时请求 \(cfg.concurrency) 个", value: $cfg.concurrency, in: 1...8)
            NavigationLink {
                Form {
                    Section {
                        TextField("如：人名保留英文、口语化、粤语对白翻成普通话", text: $cfg.extraPrompt, axis: .vertical)
                            .lineLimit(4...12)
                    } footer: { Text("会附加在 AI 翻译的提示词后面。留空用默认规则。") }
                }
                .navigationTitle("自定义翻译规则")
            } label: {
                LabeledContent("自定义翻译规则", value: cfg.extraPrompt.isEmpty ? "默认" : "已设置")
            }
            Button {
                testing = true; testResult = nil
                Task { testResult = await AITranslator.test(); testing = false }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("测试翻译服务")
                        Text("发送一句测试字幕，确认当前配置可以完成翻译。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if testing { ProgressView() } else { Image(systemName: "globe") }
                }
            }
            .disabled(testing || !cfg.isReady)
            if let r = testResult { Text(r).font(.footnote).foregroundStyle(r.hasPrefix("连接成功") ? .green : .orange) }
        } header: { Text("AI 翻译") } footer: {
            Text("用大模型翻译外挂字幕，比系统翻译更懂影视口语。Key 获取：\(cfg.provider.keyHint)。Key 只保存在本机钥匙串。")
        }
    }
}
