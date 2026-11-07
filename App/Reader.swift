import SwiftUI
import AVFoundation

enum ReaderTheme: String, CaseIterable, Identifiable {
    case auto, paper, night
    var id: String { rawValue }
    var label: String {
        switch self { case .auto: return "跟随系统"; case .paper: return "纸张"; case .night: return "夜间" }
    }
    var scheme: ColorScheme? {
        switch self { case .auto: return nil; case .paper: return .light; case .night: return .dark }
    }
}

enum ReaderPrefs {
    static let sizes: [DynamicTypeSize] = [.small, .medium, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1]
    static func size(_ i: Int) -> DynamicTypeSize { sizes[min(max(i, 0), sizes.count - 1)] }
}

/// Remembers how far each long article was read (index of the top visible block).
enum ReadingProgress {
    private static let key = "readingProgress"
    private static var all: [String: Int] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }
    static func position(_ id: String) -> Int? { all[id] }
    static func save(_ id: String, _ p: Int) {
        var d = all
        guard d[id] != p else { return }
        d[id] = p
        if d.count > 300 {
            let extra = Array(d.keys.filter { $0 != id }.prefix(d.count - 300))
            for k in extra { d[k] = nil }
        }
        UserDefaults.standard.set(d, forKey: key)
    }
    static func clear(_ id: String) {
        var d = all
        guard d[id] != nil else { return }
        d[id] = nil
        UserDefaults.standard.set(d, forKey: key)
    }
}

struct ReaderBackground: View {
    let theme: ReaderTheme
    var body: some View {
        switch theme {
        case .auto: AuroraBackground().opacity(0.45)
        case .paper: Color(red: 0.97, green: 0.94, blue: 0.87).ignoresSafeArea()
        case .night: Color.black.ignoresSafeArea()
        }
    }
}

struct ReaderScheme: ViewModifier {
    let theme: ReaderTheme
    @ViewBuilder
    func body(content: Content) -> some View {
        if let s = theme.scheme { content.environment(\.colorScheme, s) } else { content }
    }
}

/// Font size, line spacing, serif, theme and speech speed.
struct ReaderSettingsForm: View {
    @AppStorage("readerSize") private var size = 2
    @AppStorage("readerSpacing") private var spacing = 6.0
    @AppStorage("readerSerif") private var serif = false
    @AppStorage("readerTheme") private var theme = ReaderTheme.auto.rawValue
    @AppStorage("speechRate") private var speechRate = 0.5
    @AppStorage("speechEngine") private var speechEngine = "edge"
    @AppStorage("edgeVoice") private var edgeVoice = EdgeTTS.defaultVoice
    @AppStorage("edgePitch") private var edgePitch = 0
    @AppStorage("systemVoice") private var systemVoice = ""
    @State private var previewing = false
    @State private var previewFailed = false
    @AppStorage("compactList") private var compact = false
    @AppStorage("groupByDay") private var groupByDay = true
    @AppStorage("autoFullText") private var autoFullText = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "textformat.size.smaller")
                    Slider(value: Binding(get: { Double(size) }, set: { size = Int($0.rounded()) }),
                           in: 0...Double(ReaderPrefs.sizes.count - 1), step: 1)
                    Image(systemName: "textformat.size.larger")
                }
                Picker("行距", selection: $spacing) {
                    Text("紧凑").tag(3.0); Text("标准").tag(6.0); Text("宽松").tag(10.0)
                }
                .pickerStyle(.segmented)
                Toggle("衬线字体", isOn: $serif)
                Toggle("打开时自动显示全文", isOn: $autoFullText)
                Picker("主题", selection: $theme) {
                    ForEach(ReaderTheme.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("文章")
            }
            Section {
                Picker("朗读引擎", selection: $speechEngine) {
                    Text("自然语音").tag("edge"); Text("系统语音").tag("system")
                }
                .pickerStyle(.segmented)
                if speechEngine == "edge" {
                    Picker("声音", selection: $edgeVoice) {
                        ForEach(EdgeTTS.voices) { v in Text("\(v.name) · \(v.desc)").tag(v.id) }
                    }
                    Picker("音调", selection: $edgePitch) {
                        Text("低沉").tag(-10); Text("自然").tag(0); Text("明亮").tag(10)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        previewing = true
                        Task {
                            previewFailed = !(await Speaker.shared.preview(voice: edgeVoice))
                            previewing = false
                        }
                    } label: {
                        HStack {
                            Label("试听", systemImage: "play.circle")
                            if previewing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(previewing)
                    if previewFailed {
                        Text("连不上在线语音，朗读时会自动改用系统语音。").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("声音", selection: $systemVoice) {
                        Text("自动").tag("")
                        ForEach(SystemVoices.chinese, id: \.identifier) { v in Text(SystemVoices.label(v)).tag(v.identifier) }
                    }
                }
                Picker("朗读速度", selection: $speechRate) {
                    Text("慢").tag(0.42); Text("标准").tag(0.5); Text("快").tag(0.56)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("朗读")
            } footer: {
                Text(speechEngine == "edge" ? "自然语音来自微软在线服务，需要联网；其他语言的文章会自动换成同性别的对应声音。" : "更好听的系统声音可在「设置 > 辅助功能 > 朗读内容 > 声音」下载增强版或高级版。")
            }
            Section {
                Toggle("按日期分组", isOn: $groupByDay)
                Picker("列表样式", selection: $compact) {
                    Text("卡片").tag(false); Text("紧凑").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("文章列表")
            } footer: {
                Text("在列表里左滑标已读，右滑收藏或稍后读。")
            }
        }
    }
}

struct ReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ReaderSettingsForm()
                .navigationTitle("阅读设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

enum SystemVoices {
    static var chinese: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }
    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let g: String
        switch v.gender { case .male: g = "男"; case .female: g = "女"; default: g = "" }
        let q: String
        switch v.quality { case .premium: q = " · 高级"; case .enhanced: q = " · 增强"; default: q = "" }
        let region = v.language == "zh-CN" ? "" : (v.language == "zh-HK" ? " · 粤语" : " · 台湾")
        return "\(v.name)\(g.isEmpty ? "" : " · " + g)\(region)\(q)"
    }
}
