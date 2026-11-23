import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @State private var tmdbStatus: String?
    @State private var testing = false
    enum Page: Hashable, Identifiable { case play, av, control, ai; var id: Self { self } }
    @State private var page: Page?
    @AppStorage(MetaSource.key) private var metaSource = "tmdb"

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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            SourceCard(name: "TMDB", detail: "海报 · 评分 · 简介", color: Color(red: 0.01, green: 0.15, blue: 0.25),
                                       accent: Color(red: 0.0, green: 0.82, blue: 0.67), selected: metaSource != "douban") { metaSource = "tmdb" }
                            SourceCard(name: "豆瓣", detail: "TMDB 海报 + 豆瓣评分简介", color: Color(red: 0.0, green: 0.45, blue: 0.12),
                                       accent: .white, selected: metaSource == "douban") {
                                metaSource = "douban"
                                Task { await library.enrichDouban() }
                            }
                        }
                        .padding(.horizontal, 2).padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } header: { Text("刮削源") } footer: {
                    Text("选豆瓣时，海报、分类和剧集仍来自 TMDB，评分和简介换成豆瓣的（找不到时沿用 TMDB）。豆瓣资料会在后台逐部补全。")
                }

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

/// Title + grey caption row label.
struct SettingRowLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct PlaybackSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @State private var mpvCrashed = MPVGuard.crashed
    @AppStorage("play.autoNext") private var autoNext = true
    @AppStorage("play.skipIntro") private var skipIntro = false
    @AppStorage("play.onlineSegments") private var onlineSegs = true
    @AppStorage("play.skipCredits") private var skipCredits = false
    @AppStorage("play.skipPreview") private var skipPreview = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $autoNext) { SettingRowLabel(title: "自动播放下一集", detail: "剧集结束后继续下一集") }
                Toggle(isOn: $settings.resumePlayback) { SettingRowLabel(title: "记忆播放进度", detail: "下次从离开的位置继续") }
                Toggle(isOn: $skipIntro) { SettingRowLabel(title: "自动跳过片头和回顾", detail: "按在线匹配或手动标记的时间跳过，手动修正优先") }
                Toggle(isOn: $onlineSegs) { SettingRowLabel(title: "在线匹配片头片尾", detail: "使用 TheIntroDB，需要影片已刮削到 TMDB") }
                Toggle(isOn: $skipCredits) { SettingRowLabel(title: "自动跳过片尾", detail: "按片尾区间跳过，保留已识别的彩蛋") }
                Toggle(isOn: $skipPreview) { SettingRowLabel(title: "自动跳过预告", detail: "仅在匹配到可靠时间时自动跳过") }
            } header: { Text("播放习惯") } footer: {
                Text("播放时右上角「片头片尾」按钮可把当前位置标为片头结束或片尾开始，整部剧通用。没开自动跳过时，到片头会显示「跳过片头」按钮。")
            }

            Section {
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
            } header: { Text("播放内核") } footer: {
                Text("原生内核支持杜比视界、HDR10、杜比全景声和空间音频（SMB 来源除外）。MKV 内核选「自动」时，文件名带杜比视界 / HDR / 4K / HEVC / Atmos / TrueHD 的用 MPV，其他用 VLC；SMB 在线播放始终用 VLC。")
            }
        }
    }
}

struct SubtitleSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @AppStorage("av.fill") private var fill = 0
    @AppStorage("av.serverQuality") private var quality = 0
    @AppStorage("av.followVideo") private var followVideo = true
    @AppStorage("av.pip") private var pip = true
    @AppStorage("av.pipAuto") private var pipAuto = true

    var body: some View {
        Form {
            Section {
                Picker(selection: $fill) {
                    Text("默认").tag(0); Text("填充").tag(1); Text("拉伸").tag(2)
                } label: { SettingRowLabel(title: "默认画面", detail: "16:9 影片在手机上两端会留黑边；填充会裁掉上下") }
                Toggle(isOn: $settings.dolbyStereo) { SettingRowLabel(title: "杜比音轨兼容模式", detail: "TrueHD / E-AC3 多声道混成立体声，解决没声音") }
                Picker(selection: $quality) {
                    Text("原画").tag(0); Text("1080P 20M").tag(20); Text("1080P 10M").tag(10); Text("720P 4M").tag(4); Text("480P 2M").tag(2)
                } label: { SettingRowLabel(title: "媒体服务器清晰度", detail: "Emby / Jellyfin。原画直接播放；其他清晰度由服务器转码") }
            } header: { Text("音画") }

            Section {
                Toggle(isOn: $followVideo) { SettingRowLabel(title: "跟随视频方向", detail: "竖屏视频竖着播放") }
            } header: { Text("画面") }

            Section {
                Toggle(isOn: $pip) { SettingRowLabel(title: "画中画", detail: "播放时可缩成小窗口") }
                Toggle(isOn: $pipAuto) { SettingRowLabel(title: "回到桌面自动画中画", detail: "播放中上滑回到桌面，视频以小画面继续播放") }
                    .disabled(!pip)
            } header: { Text("画中画") } footer: {
                Text("画中画目前只支持苹果原生内核（MP4 / MOV / M4V，需在「播放」里打开原生内核）。VLC / MPV 播放的 MKV 等格式暂不支持。")
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
    @AppStorage("ai.enabled") private var aiOn = true
    @AppStorage("aitr.enabled") private var aiTrOn = true
    @State private var usage = AIUsage.rows

    var body: some View {
        Form {
            Section { Toggle("启用 AI 字幕", isOn: $aiOn) }

            if aiOn {
                Section {
                    Picker("影片原声语言", selection: $settings.aiSpeechLocale) {
                        ForEach(AILanguages.speech, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("用系统翻译翻成目标语言", isOn: $settings.aiTranslate)
                    Toggle("同时显示原文", isOn: $settings.aiShowOriginal)
                } header: { Text("语音转字幕 · Beta") } footer: {
                    Text("识别音轨中的语音生成字幕，在 iPhone 本机运行，会占用额外内存。播放时在字幕菜单里打开「AI 实时字幕」。")
                }

                Section { Toggle("使用 AI 翻译", isOn: $aiTrOn) } header: { Text("字幕翻译") }
                if aiTrOn { AITranslateSettings() }

                Section {
                    if usage.isEmpty {
                        Text("还没有翻译记录").foregroundStyle(.secondary)
                    }
                    ForEach(usage) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.model).lineLimit(1)
                                Text("输入 \(r.input.formatted()) · 输出 \(r.output.formatted()) · \(r.calls) 次").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\((r.input + r.output).formatted()) tokens").foregroundStyle(.secondary)
                        }
                    }
                    if !usage.isEmpty {
                        Button("清空用量记录", role: .destructive) { AIUsage.reset(); usage = [] }
                    }
                } header: { Text("翻译用量") } footer: {
                    Text("记录这台设备用于字幕翻译的累计 token 用量，仅供参考。实际费用以服务商账单为准。")
                }

                Section {
                    Picker("翻译成", selection: $settings.translateTarget) {
                        ForEach(AILanguages.targets, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("翻译外挂字幕时保留原文（双语）", isOn: $settings.bilingualSubs)
                } header: { Text("系统翻译") } footer: {
                    Text("使用 iPhone 自带的「翻译」，语言包下载后可离线使用。")
                }
            }
        }
        .onAppear { usage = AIUsage.rows }
    }
}

struct ControlSettingsPage: View {
    @AppStorage("ctl.followRotation") private var followRotation = true
    @AppStorage("ctl.rotateButton") private var rotateButton = true
    @AppStorage("ctl.nextButton") private var nextButton = true
    @AppStorage("ctl.seekButtons") private var seekButtons = true
    @AppStorage("ctl.shotButton") private var shotButton = true
    @AppStorage("ctl.fwd") private var fwd = 10
    @AppStorage("ctl.back") private var back = 10
    @AppStorage("ctl.dtCenter") private var dtCenter = "play"
    @AppStorage("ctl.dtSides") private var dtSides = "seek"
    @AppStorage("ctl.swipeLevels") private var swipeLevels = true
    @AppStorage("ctl.pinch") private var pinch = true
    @AppStorage("ctl.lockGestures") private var lockGestures = true
    @AppStorage("ctl.defaultRate") private var defaultRate = 1.0
    @AppStorage("ctl.longPress") private var longPress = true
    @AppStorage("ctl.longRate") private var longRate = 2.0
    @AppStorage("ctl.longSlide") private var longSlide = true
    @AppStorage("ctl.longLock") private var longLock = true
    @AppStorage("ctl.longRestore") private var longRestore = "prev"
    @AppStorage("ctl.hide") private var hideAfter = 4.0
    private let steps = [5, 10, 15, 30, 45, 60]

    var body: some View {
        Form {
            Section {
                Toggle("跟随设备旋转", isOn: $followRotation)
                Toggle("显示转屏按钮", isOn: $rotateButton)
            }
            Section {
                NavigationLink("播放器按钮") { PlayerButtonsPage().navigationTitle("播放器按钮") }
                Toggle("下一集 按钮", isOn: $nextButton)
                Toggle("快进与快退按钮", isOn: $seekButtons)
                Toggle("截图 按钮", isOn: $shotButton)
                Picker("快进时长", selection: $fwd) { ForEach(steps, id: \.self) { Text("\($0)秒").tag($0) } }
                Picker("快退时长", selection: $back) { ForEach(steps, id: \.self) { Text("\($0)秒").tag($0) } }
                Picker("控制栏自动隐藏", selection: $hideAfter) {
                    ForEach([2.0, 4.0, 6.0, 10.0], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                }
            } header: { Text("播放器按钮") }
            Section {
                Picker("双击中间触发", selection: $dtCenter) { Text("播放 / 暂停").tag("play"); Text("无").tag("none") }
                Picker("双击两侧触发", selection: $dtSides) { Text("快进 / 快退").tag("seek"); Text("播放 / 暂停").tag("play"); Text("无").tag("none") }
                Toggle("全屏上下滑动调整音量和亮度", isOn: $swipeLevels)
                Toggle("双指缩放画面", isOn: $pinch)
                Toggle("锁定时允许长按和双击操作", isOn: $lockGestures)
            } header: { Text("手势操作") } footer: {
                Text("左半边上下滑调亮度，右半边调音量。双指张开填充屏幕，捏合恢复。")
            }
            Section {
                Picker("默认播放速度", selection: $defaultRate) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text("\($0, specifier: "%g")x").tag($0) }
                }
                Toggle("长按快进", isOn: $longPress)
                Picker("默认长按倍速", selection: $longRate) {
                    ForEach([1.5, 2.0, 2.5, 3.0], id: \.self) { Text("\($0, specifier: "%g")x").tag($0) }
                }
                Toggle("快进时左右滑动调整速度", isOn: $longSlide)
                Toggle("快进时向上滑动锁定", isOn: $longLock)
                Picker(selection: $longRestore) {
                    Text("长按前速度").tag("prev"); Text("1.0x").tag("one")
                } label: { SettingRowLabel(title: "长按松手时恢复至", detail: "松开后回到长按前的播放速度") }
            } header: { Text("倍速与快进") }
        }
    }
}

struct PlayerButtonsPage: View {
    @AppStorage("ctl.btnSkipMarks") private var marks = true
    @AppStorage("ctl.btnSub") private var sub = true
    @AppStorage("ctl.btnAudio") private var audio = true
    @AppStorage("ctl.btnSpeed") private var speed = true
    var body: some View {
        Form {
            Section {
                Toggle("片头片尾 按钮", isOn: $marks)
                Toggle("字幕 按钮", isOn: $sub)
                Toggle("音轨 按钮", isOn: $audio)
                Toggle("倍速 按钮", isOn: $speed)
            } footer: { Text("控制播放器右上角显示哪些按钮。") }
        }
    }
}


/// Thumbnail-style card for picking the metadata source; white frame = selected.
struct SourceCard: View {
    let name: String
    let detail: String
    let color: Color
    let accent: Color
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.title2.weight(.heavy)).foregroundStyle(accent)
                Spacer(minLength: 0)
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
            .padding(12)
            .frame(width: 170, height: 100, alignment: .leading)
            .background(color, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.white : Color.clear, lineWidth: 3))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).padding(8) }
            }
        }
        .buttonStyle(.plain)
    }
}
