import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @State private var tmdbStatus: String?
    @State private var testing = false
    enum Page: Hashable, Identifiable { case play, av, control, ai; var id: Self { self } }
    @State private var page: Page?
    @AppStorage(MetaSource.key) private var metaSource = "tmdb"
    @ObservedObject private var sourceStore = SourceStore.shared
    @State private var cd2Edit: MediaSource?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StorageCard()
                        .background(NavigationLink("") { StorageDetailView() }.opacity(0))
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
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
                    Text("选豆瓣时，海报、分类和剧集仍来自 TMDB，评分和简介换成豆瓣的（找不到时沿用 TMDB）。后台会逐部查豆瓣资料，豆瓣类型含「同性」的会归到 BL。")
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

                Section {
                    ForEach(sourceStore.sources.filter { $0.kind == .cd2 }) { src in
                        Button { cd2Edit = src } label: {
                            HStack {
                                Image(systemName: "externaldrive.badge.icloud").foregroundStyle(.teal)
                                VStack(alignment: .leading) {
                                    Text(src.name).foregroundStyle(.primary)
                                    Text(src.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    Button {
                        cd2Edit = MediaSource(kind: .cd2, name: "CloudDrive2")
                    } label: { Label("登录 CloudDrive2", systemImage: "plus.circle") }
                } header: { Text("CloudDrive2") } footer: {
                    Text("连接电脑或 NAS 上运行的 CloudDrive2，直接浏览它挂载的所有网盘。添加后也会出现在「文件源」里。")
                }

                Section("媒体库") {
                    LabeledContent("影片数量", value: "\(library.items.count)")
                    LabeledContent("视频文件", value: "\(library.items.reduce(0) { $0 + $1.files.count })")
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
            .sheet(item: $cd2Edit) { src in SourceEditor(source: src).environmentObject(SourceStore.shared) }
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
                if settings.nativeEngine {
                    Toggle(isOn: $settings.nativeRemux) { SettingRowLabel(title: "MKV 重封装给原生内核", detail: "实验：杜比视界 / 全景声走苹果原生，内封字幕暂不显示；失败自动换 VLC/MPV") }
                }
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


// MARK: - 空间占用

struct StorageCard: View {
    struct Part: Identifiable { let id: String; let color: Color; var bytes: Int64 }
    @State private var parts: [Part] = []

    private var total: Int64 { parts.reduce(0) { $0 + $1.bytes } }
    private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("空间占用").foregroundStyle(.secondary)
                Spacer()
                Text(parts.isEmpty ? "计算中…" : fmt(total)).font(.title3.monospacedDigit())
            }
            GeometryReader { g in
                HStack(spacing: 3) {
                    let shown = parts.filter { $0.bytes > 0 }
                    let avail = g.size.width - CGFloat(max(0, shown.count - 1)) * 3
                    ForEach(shown) { p in
                        Rectangle().fill(p.color)
                            .frame(width: max(4, avail * CGFloat(Double(p.bytes) / Double(max(total, 1)))))
                    }
                    if shown.isEmpty { Rectangle().fill(Color.secondary.opacity(0.3)) }
                }
                .clipShape(Capsule())
            }
            .frame(height: 18)
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Spacer(minLength: 6) }
                    HStack(spacing: 4) {
                        Circle().fill(p.color).frame(width: 8, height: 8)
                        Text(p.id).font(.footnote).lineLimit(1).fixedSize()
                    }
                }
            }
            .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .task { await measure() }
    }

    private func measure() async {
        let r = await Task.detached(priority: .utility) { () -> [Part] in
            let fm = FileManager.default
            func size(_ u: URL) -> Int64 {
                var t: Int64 = 0
                guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
                for case let f as URL in e {
                    let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                    if v?.isRegularFile == true { t += Int64(v?.totalFileAllocatedSize ?? 0) }
                }
                return t
            }
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let sup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let all = size(home)
            let video = size(fm.temporaryDirectory)
            let images = size(caches)
            let downloads = size(sup.appendingPathComponent("Downloads"))
            let ai = size(sup.appendingPathComponent("Models")) + size(sup.appendingPathComponent("Fonts"))
            let lib = ["library.json", "tmdb-cache.json", "scan"].reduce(Int64(0)) { $0 + size(sup.appendingPathComponent($1)) }
                + ((try? fm.attributesOfItem(atPath: sup.appendingPathComponent("library.json").path)[.size] as? Int64) ?? 0) * 0
            let other = max(0, all - video - images - downloads - ai - lib)
            return [Part(id: "视频", color: .indigo, bytes: video), Part(id: "图片", color: .orange, bytes: images),
                    Part(id: "资源库", color: .blue, bytes: lib), Part(id: "下载", color: .green, bytes: downloads),
                    Part(id: "AI 模型", color: .cyan, bytes: ai), Part(id: "其他", color: .gray, bytes: other)]
        }.value
        parts = r
    }
}

/// 存储与缓存: one row per kind of data the app really keeps (only features we have).
/// Long-press (or tap) a row → 「要清理 X 吗？」. When a new feature adds its own cache, add its row here.
struct StorageDetailView: View {
    struct Row: Identifiable { let id: String; let dirs: [URL]; var bytes: Int64 = 0; var count = 0 }
    @State private var rows: [Row] = []
    @State private var ask: Row?
    @State private var askAll = false

    static func kinds() -> [Row] {
        let fm = FileManager.default
        let sup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let tmp = fm.temporaryDirectory
        return [
            Row(id: "文档目录", dirs: [fm.urls(for: .documentDirectory, in: .userDomainMask)[0]]),
            Row(id: "图片缓存", dirs: [fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]]),
            Row(id: "视频缓存", dirs: [tmp]),
            Row(id: "字幕缓存", dirs: [tmp.appendingPathComponent("subs")]),
            Row(id: "数据请求缓存", dirs: [sup.appendingPathComponent("tmdb-cache.json"), sup.appendingPathComponent("scan")]),
            Row(id: "离线下载", dirs: [sup.appendingPathComponent("Downloads")]),
            Row(id: "AI 字幕模型", dirs: [sup.appendingPathComponent("Models")]),
        ]
    }
    private static let cacheKinds: Set<String> = ["图片缓存", "视频缓存", "字幕缓存", "数据请求缓存"]
    private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        Form {
            Section {
                ForEach(rows) { r in
                    HStack {
                        Text(r.id)
                        Spacer()
                        Text(fmt(r.bytes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { ask = r }
                    .onLongPressGesture { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); ask = r }
                }
            } footer: { Text("长按或点按某一项可单独清理。") }
            Section {
                Button(role: .destructive) { askAll = true } label: { Text("清理全部缓存").frame(maxWidth: .infinity) }
            } footer: { Text("清理图片、视频、字幕和数据请求缓存；文档、下载和 AI 模型不受影响。") }
        }
        .navigationTitle("存储与缓存").navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
        .alert("要清理 \(ask?.id ?? "") 吗？", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })) {
            Button("取消", role: .cancel) { ask = nil }
            Button("清理", role: .destructive) { if let r = ask { clear([r]) }; ask = nil }
        } message: {
            if ask?.id == "文档目录" { Text("会删除导入到本机文档目录的文件。") }
            else if ask?.id == "离线下载" { Text("已下载的视频会被删除。") }
        }
        .alert("要清理全部缓存吗？", isPresented: $askAll) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { clear(rows.filter { Self.cacheKinds.contains($0.id) }) }
        }
    }

    private func clear(_ list: [Row]) {
        let fm = FileManager.default
        for r in list {
            if r.id == "图片缓存" { URLCache.shared.removeAllCachedResponses(); PosterCache.shared.clearMemory() }
            for d in r.dirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: d.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: u) }
                } else { try? fm.removeItem(at: d) }
            }
        }
        Task { await measure() }
    }

    private func measure() async {
        rows = await Task.detached(priority: .utility) { () -> [Row] in
            let fm = FileManager.default
            func size(_ u: URL) -> (Int64, Int) {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return (0, 0) }
                if !isDir.boolValue {
                    let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    return (Int64(v?.totalFileAllocatedSize ?? 0), 1)
                }
                var t: Int64 = 0, n = 0
                guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return (0, 0) }
                for case let f as URL in e {
                    let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                    if v?.isRegularFile == true { t += Int64(v?.totalFileAllocatedSize ?? 0); n += 1 }
                }
                return (t, n)
            }
            var out = StorageDetailView.kinds()
            let subs = size(fm.temporaryDirectory.appendingPathComponent("subs")).0
            for i in out.indices {
                for d in out[i].dirs { let (b, n) = size(d); out[i].bytes += b; out[i].count += n }
                if out[i].id == "视频缓存" { out[i].bytes = max(0, out[i].bytes - subs) }
            }
            return out
        }.value
    }
}
