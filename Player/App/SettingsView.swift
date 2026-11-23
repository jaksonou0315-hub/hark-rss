import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @State private var tmdbStatus: String?
    @State private var testing = false
    enum Page: Hashable, Identifiable { case play, av, control, ai; var id: Self { self } }
    @State private var page: Page?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        SettingsTile(title: "播放", icon: "slider.horizontal.3") { page = .play }
                        SettingsTile(title: "音画", icon: "play.rectangle") { page = .av }
                        SettingsTile(title: "操控", icon: "hand.tap") { page = .control }
                        SettingsTile(title: "AI 字幕", icon: "text.bubble") { page = .ai }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } header: { Text("播放体验") }

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

                Section("媒体库") {
                    LabeledContent("影片数量", value: "\(library.items.count)")
                    Button("完整重新扫描") { Task { await library.scan(force: true) } }
                    NavigationLink("扫描诊断") { ScanDiagnosticsView() }
                    NavigationLink("下载管理") { DownloadsView() }
                    if library.removedCount > 0 {
                        Button("恢复已移除的影片（\(library.removedCount) 个文件）") {
                            library.restoreRemoved()
                            Task { await library.scan(force: false) }
                        }
                    }
                }

                Section {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("解码内核", value: "VLCKit 3.6 (FFmpeg)")
                } header: { Text("关于 Hark 影音") }
            }
            .navigationTitle("设置")
            .navigationDestination(item: $page) { p in
                switch p {
                case .play: PlaybackSettingsPage().navigationTitle("播放")
                case .av: SubtitleSettingsPage().navigationTitle("音画")
                case .control: ControlSettingsPage().navigationTitle("操控")
                case .ai: AISettingsPage().navigationTitle("AI 字幕")
                }
            }
        }
    }
}

/// Square shortcut tile used in 「播放体验」.
struct SettingsTile: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.title2).frame(height: 28)
                Text(title).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

struct PlaybackSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @State private var mpvCrashed = MPVGuard.crashed
    var body: some View {
        Form {
                Section {
                    Toggle("记住播放进度", isOn: $settings.resumePlayback)
                    Toggle("MP4/MOV 用苹果原生内核", isOn: $settings.nativeEngine)
                    Picker("MKV 等格式播放内核", selection: $settings.mkvEngine) {
                        ForEach(EngineKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if FileManager.default.fileExists(atPath: MPVLog.file.path) {
                        ShareLink(item: MPVLog.combined()) { Label("导出 MPV 日志", systemImage: "square.and.arrow.up") }
                    }
                    if mpvCrashed {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("MPV 上次在「\(MPVGuard.crashStep ?? "未知")」阶段闪退，自动模式已改用 VLC。").font(.footnote).foregroundStyle(.orange)
                            Button("重新启用 MPV") { MPVGuard.reset(); mpvCrashed = false }.font(.footnote)
                        }
                    }
                } header: { Text("播放") } footer: {
                    Text("原生内核支持杜比视界、HDR10、杜比全景声和空间音频（SMB 来源除外）。MKV 内核选「自动」时，文件名带杜比视界 / HDR / 4K / HEVC / Atmos / TrueHD 的用 MPV（能正确显示杜比视界色彩），其他用 VLC；SMB 在线播放始终用 VLC。")
                }

        }
    }
}
struct SubtitleSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        Form {
                Section {
                    Toggle("杜比音轨兼容模式", isOn: $settings.dolbyStereo)
                } header: { Text("音频") } footer: {
                    Text("把 MKV 里的 TrueHD / E-AC3 多声道混成立体声，解决没声音的问题。")
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

                SubtitleStyleEditor()
        }
    }
}
struct AISettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        Form {
                Section {
                    Picker("影片原声语言", selection: $settings.aiSpeechLocale) {
                        ForEach(AILanguages.speech, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("用系统翻译翻成目标语言", isOn: $settings.aiTranslate)
                    Toggle("同时显示原文", isOn: $settings.aiShowOriginal)
                } header: { Text("AI 字幕") } footer: {
                    Text("播放时在字幕菜单里打开「AI 实时字幕」：用 iPhone 本机语音识别听影片声音生成字幕。首次需要允许语音识别和「录制屏幕」（只用于读取本 App 的声音，不保存、不上传）。")
                }

                AITranslateSettings()

                Section {
                    Picker("翻译成", selection: $settings.translateTarget) {
                        ForEach(AILanguages.targets, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("翻译外挂字幕时保留原文（双语）", isOn: $settings.bilingualSubs)
                } header: { Text("系统翻译") } footer: {
                    Text("使用 iPhone 自带的「翻译」，语言包下载后可离线使用。可在「设置 › App › 翻译」管理已下载的语言。")
                }

        }
    }
}

struct ControlSettingsPage: View {
    @AppStorage("ctl.doubleTap") private var doubleTapSeek = true
    @AppStorage("ctl.seek") private var seekStep = 10
    @AppStorage("ctl.hide") private var hideAfter = 4.0

    var body: some View {
        Form {
            Section {
                Toggle("双击左右两侧快退 / 快进", isOn: $doubleTapSeek)
                Picker("快进 / 快退步长", selection: $seekStep) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) 秒").tag($0) }
                }
            } header: { Text("手势") } footer: {
                Text("关闭双击后，双击和单击一样只显示或隐藏控制栏。步长同时用于控制栏上的快进 / 快退按钮。")
            }
            Section {
                Picker("控制栏自动隐藏", selection: $hideAfter) {
                    ForEach([2.0, 4.0, 6.0, 10.0], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                }
            } header: { Text("控制栏") }
        }
    }
}
