import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @State private var tmdbStatus: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("TMDB API Key 或 Read Access Token", text: $settings.tmdbKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("资料语言", selection: $settings.tmdbLanguage) {
                        Text("简体中文").tag("zh-CN"); Text("繁體中文").tag("zh-TW"); Text("English").tag("en-US"); Text("日本語").tag("ja-JP")
                    }
                    Button {
                        Task {
                            testing = true
                            do { try await TMDB.test(); tmdbStatus = "✅ Key 可用" } catch { tmdbStatus = "❌ \(error.localizedDescription)" }
                            testing = false
                        }
                    } label: { HStack { Text("测试 TMDB 连接"); if testing { Spacer(); ProgressView() } } }
                    if let tmdbStatus { Text(tmdbStatus).font(.footnote) }
                } header: { Text("海报墙 · TMDB") } footer: {
                    Text("在 themoviedb.org › 设置 › API 免费申请。Key 只保存在本机钥匙串中。")
                }

                Section {
                    Toggle("自动加载同名外挂字幕", isOn: $settings.autoSidecar)
                    Picker("首选字幕语言", selection: $settings.preferredSubLang) {
                        Text("中文").tag("zh"); Text("英文").tag("en"); Text("不自动选择").tag("")
                    }
                    Picker("内封文本字幕编码", selection: $settings.subtitleEncoding) {
                        Text("自动").tag(""); Text("GB18030（简体）").tag("GB18030"); Text("Big5（繁体）").tag("Big5"); Text("UTF-8").tag("UTF-8")
                    }
                    Toggle("没有字幕时自动在线搜索", isOn: $settings.autoOnlineSubtitle)
                } header: { Text("字幕") } footer: {
                    Text("外挂字幕（.srt/.ass/.ssa/.vtt）会自动转为 UTF-8，GBK/Big5 编码也能正常显示。")
                }

                Section {
                    SecureField("射手网 (assrt.net) API Token", text: $settings.assrtToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("OpenSubtitles API Key", text: $settings.openSubtitlesKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("在线字幕") } footer: {
                    Text("射手网：assrt.net 登录后在「用户面板」获取 Token；OpenSubtitles：opensubtitles.com › API Consumers 创建 Key。")
                }

                Section("播放") {
                    Toggle("记住播放进度", isOn: $settings.resumePlayback)
                }

                Section("媒体库") {
                    LabeledContent("影片数量", value: "\(library.items.count)")
                    Button("重新扫描") { Task { await library.scan() } }
                }

                Section {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("解码内核", value: "VLCKit 3.6 (FFmpeg)")
                } header: { Text("关于 Hark 影音") }
            }
            .navigationTitle("设置")
        }
    }
}
