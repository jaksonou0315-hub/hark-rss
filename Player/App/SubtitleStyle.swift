import SwiftUI
import AVFoundation
import CoreText
import UniformTypeIdentifiers

/// User-adjustable look of text subtitles (SRT/VTT and plain embedded text tracks).
/// ASS/SSA tracks keep their own styling (rendered by libass).
final class SubtitleStyle: ObservableObject {
    static let shared = SubtitleStyle()
    private let d = UserDefaults.standard

    /// 0xRRGGBB
    @Published var color: Int { didSet { d.set(color, forKey: "subStyle.color") } }
    /// 50 ... 200 (%)
    @Published var scale: Double { didSet { d.set(scale, forKey: "subStyle.scale") } }
    /// 0 常规, 1 中粗, 2 粗, 3 特粗. Player engines only have bold on/off (on from 粗); AI captions use every step.
    @Published var weight: Int { didSet { d.set(weight, forKey: "subStyle.weight") } }
    var bold: Bool { weight >= 2 }
    static let weightNames = ["常规", "中粗", "粗", "特粗"]
    static let outlineNames = ["无", "细", "中", "粗"]
    /// 0 none, 1 thin, 2 normal, 3 thick
    @Published var outline: Int { didSet { d.set(outline, forKey: "subStyle.outline") } }
    @Published var background: Bool { didSet { d.set(background, forKey: "subStyle.bg") } }
    /// 0 ... 1
    @Published var backgroundOpacity: Double { didSet { d.set(backgroundOpacity, forKey: "subStyle.bgOpacity") } }
    /// font family name, "" = system default
    @Published var font: String { didSet { d.set(font, forKey: "subStyle.font") } }
    @Published var importedFamilies: [String] = []

    static let presetColors: [(String, Int)] = [("白", 0xFFFFFF), ("黄", 0xFFE14D), ("浅蓝", 0x7FD4FF), ("绿", 0x8CFF9E), ("粉", 0xFF8FC7), ("橙", 0xFFAE5C)]
    static let curatedFonts: [(String, String)] = [
        ("苹方", "PingFang SC"), ("黑体", "Heiti SC"), ("宋体", "Songti SC"), ("楷体", "Kaiti SC"), ("圆体", "Yuanti SC"),
        ("翩翩体", "HanziPen SC"), ("冬青黑体", "Hiragino Sans GB"), ("Helvetica Neue", "Helvetica Neue"),
        ("Avenir Next", "Avenir Next"), ("Georgia", "Georgia"), ("Menlo", "Menlo")
    ]

    private init() {
        color = d.object(forKey: "subStyle.color") as? Int ?? 0xFFFFFF
        scale = d.object(forKey: "subStyle.scale") as? Double ?? 100
        weight = d.object(forKey: "subStyle.weight") as? Int ?? ((d.object(forKey: "subStyle.bold") as? Bool ?? false) ? 2 : 0)
        outline = d.object(forKey: "subStyle.outline") as? Int ?? 2
        background = d.object(forKey: "subStyle.bg") as? Bool ?? false
        backgroundOpacity = d.object(forKey: "subStyle.bgOpacity") as? Double ?? 0.5
        font = d.string(forKey: "subStyle.font") ?? ""
        registerImportedFonts()
    }

    var swiftUIColor: Color {
        Color(red: Double((color >> 16) & 0xFF) / 255, green: Double((color >> 8) & 0xFF) / 255, blue: Double(color & 0xFF) / 255)
    }

    /// Fonts installed on this device worth offering, plus fonts the user imported.
    var availableFonts: [(String, String)] {
        let installed = Set(UIFont.familyNames)
        var list = Self.curatedFonts.filter { installed.contains($0.1) }
        for f in importedFamilies where !list.contains(where: { $0.1 == f }) { list.append((f, f)) }
        return list
    }

    // MARK: VLC

    var vlcRelFontSize: Int { max(4, min(40, Int((16.0 / (scale / 100)).rounded()))) }
    var vlcOutline: Int { [0, 2, 4, 6][max(0, min(3, outline))] }
    var vlcFontName: String { font.isEmpty ? "PingFang SC" : font }

    /// Options for a VLCMediaPlayer instance (freetype renderer).
    var vlcOptions: [String] {
        var o = [
            "--freetype-color=\(color)",
            "--freetype-rel-fontsize=\(vlcRelFontSize)",
            "--freetype-font=\(vlcFontName)",
            "--freetype-outline-thickness=\(vlcOutline)",
            "--freetype-outline-color=0",
            "--freetype-background-color=0",
            "--freetype-background-opacity=\(background ? Int(backgroundOpacity * 255) : 0)",
        ]
        if bold { o.append("--freetype-bold") } else { o.append("--no-freetype-bold") }
        return o
    }

    // MARK: AVPlayer

    var avTextStyleRules: [AVTextStyleRule] {
        let r = Double((color >> 16) & 0xFF) / 255, g = Double((color >> 8) & 0xFF) / 255, b = Double(color & 0xFF) / 255
        var attrs: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1.0, r, g, b],
            kCMTextMarkupAttribute_RelativeFontSize as String: scale,
            kCMTextMarkupAttribute_BoldStyle as String: bold,
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: outline == 0 ? kCMTextMarkupCharacterEdgeStyle_None
                : (outline == 3 ? kCMTextMarkupCharacterEdgeStyle_Uniform : kCMTextMarkupCharacterEdgeStyle_DropShadow),
        ]
        if !font.isEmpty { attrs[kCMTextMarkupAttribute_FontFamilyName as String] = font }
        attrs[kCMTextMarkupAttribute_BackgroundColorARGB as String] = [background ? backgroundOpacity : 0.0, 0.0, 0.0, 0.0]
        return AVTextStyleRule.textStyleRules(fromPropertyList: [attrs]) ?? []
    }

    // MARK: Imported fonts

    static var fontsDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func families(in url: URL) -> [String] {
        let descs = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
        return descs.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
    }

    func registerImportedFonts() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.fontsDir, includingPropertiesForKeys: nil)) ?? []
        var fams: [String] = []
        for f in files {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            fams.append(contentsOf: families(in: f))
        }
        importedFamilies = Array(Set(fams)).sorted()
    }

    /// Copies a .ttf/.otf/.ttc into the app and registers it. Returns the family name.
    @discardableResult
    func importFont(_ src: URL) throws -> String {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let dst = Self.fontsDir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        let fams = families(in: dst)
        guard let fam = fams.first else {
            try? FileManager.default.removeItem(at: dst)
            throw NSError(domain: "Font", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法识别这个字体文件"])
        }
        CTFontManagerRegisterFontsForURL(dst as CFURL, .process, nil)
        registerImportedFonts()
        font = fam
        return fam
    }

    func reset() {
        color = 0xFFFFFF; scale = 100; weight = 0; outline = 2; background = false; backgroundOpacity = 0.5; font = ""
    }
}

extension UTType {
    static let fontFiles: [UTType] = [UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf"), UTType(filenameExtension: "ttc"), .font].compactMap { $0 }
}

/// Style editor, used in the player's subtitle sheet and in Settings.
struct SubtitleStyleEditor: View {
    @ObservedObject var style = SubtitleStyle.shared
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Section {
            preview
            VStack(alignment: .leading, spacing: 8) {
                Text("颜色")
                HStack(spacing: 12) {
                    ForEach(SubtitleStyle.presetColors, id: \.1) { name, c in
                        Button { style.color = c } label: {
                            Circle().fill(Color(red: Double((c >> 16) & 0xFF) / 255, green: Double((c >> 8) & 0xFF) / 255, blue: Double(c & 0xFF) / 255))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Color.accentColor, lineWidth: style.color == c ? 3 : 0).padding(-3))
                                .accessibilityLabel(name)
                        }.buttonStyle(.plain)
                    }
                    ColorPicker("", selection: Binding(get: { style.swiftUIColor }, set: { col in
                        let u = UIColor(col); var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        u.getRed(&r, green: &g, blue: &b, alpha: &a)
                        style.color = (Int(max(0, min(1, r)) * 255) << 16) | (Int(max(0, min(1, g)) * 255) << 8) | Int(max(0, min(1, b)) * 255)
                    }), supportsOpacity: false).labelsHidden()
                }
            }
            FillSlider(title: "字幕大小", value: $style.scale, range: 50...200, step: 10) { "\(Int($0))%" }
            FillSlider(title: "粗细", value: Binding(get: { Double(style.weight) }, set: { style.weight = Int($0.rounded()) }),
                       range: 0...3, step: 1) { SubtitleStyle.weightNames[max(0, min(3, Int($0.rounded())))] }
            FillSlider(title: "描边", value: Binding(get: { Double(style.outline) }, set: { style.outline = Int($0.rounded()) }),
                       range: 0...3, step: 1) { SubtitleStyle.outlineNames[max(0, min(3, Int($0.rounded())))] }
            Toggle("字幕背景", isOn: $style.background)
            if style.background {
                FillSlider(title: "背景不透明度", value: $style.backgroundOpacity, range: 0.1...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
            }
            Picker("字体", selection: $style.font) {
                Text("系统默认").tag("")
                ForEach(style.availableFonts, id: \.1) { Text($0.0).font(.custom($0.1, size: 17)).tag($0.1) }
            }
            Button { importing = true } label: { Label("导入字体（.ttf / .otf）…", systemImage: "textformat") }
            if let importError { Text(importError).font(.footnote).foregroundStyle(.red) }
            Button("恢复默认样式", role: .destructive) { style.reset() }
        } header: { Text("字幕样式") } footer: {
            Text("对 SRT / VTT 等文本字幕生效；ASS 特效字幕保留自带样式。")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: UTType.fontFiles, allowsMultipleSelection: true) { r in
            importError = nil
            switch r {
            case .success(let urls):
                for u in urls { do { try style.importFont(u) } catch { importError = error.localizedDescription } }
            case .failure(let e): importError = e.localizedDescription
            }
        }
    }

    private var preview: some View {
        let base = 18.0 * style.scale / 100
        let f: Font = style.font.isEmpty ? .system(size: base, weight: style.bold ? .bold : .regular) : .custom(style.font, size: base).weight(style.bold ? .bold : .regular)
        return ZStack {
            LinearGradient(colors: [.gray.opacity(0.6), .black], startPoint: .top, endPoint: .bottom)
            Text("字幕预览 Subtitle Preview")
                .font(f)
                .foregroundStyle(style.swiftUIColor)
                .shadow(color: .black.opacity(style.outline == 0 ? 0 : 1), radius: CGFloat(style.outline) * 0.8)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(style.background ? Color.black.opacity(style.backgroundOpacity) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }
}

/// Thin, flat progress bar (no glass). Grows slightly while dragging.
struct ThinScrubber: View {
    var value: Float
    var onChanged: (Float) -> Void
    var onEnded: (Float) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let v = CGFloat(max(0, min(1, value)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28)).frame(height: dragging ? 6 : 3)
                Capsule().fill(Color.white).frame(width: w * v, height: dragging ? 6 : 3)
                Circle().fill(Color.white).frame(width: dragging ? 16 : 10, height: dragging ? 16 : 10)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: w * v - (dragging ? 8 : 5))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { withAnimation(.easeOut(duration: 0.12)) { dragging = true } }
                    onChanged(Float(max(0, min(1, g.location.x / w))))
                }
                .onEnded { g in
                    withAnimation(.easeOut(duration: 0.12)) { dragging = false }
                    onEnded(Float(max(0, min(1, g.location.x / w))))
                })
        }
        .frame(height: 28)
    }
}


/// Capsule slider that fills from the left as you drag right: title on the left, value on the right.
struct FillSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let label: (Double) -> String
    @State private var dragging = false

    private var frac: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Color.white.opacity(dragging ? 0.95 : 0.85))
                    .frame(width: max(g.size.height, g.size.width * frac))
                HStack {
                    Text(title)
                    Spacer()
                    Text(label(value)).monospacedDigit()
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .foregroundStyle(.white)
                .blendMode(.difference)
            }
            .compositingGroup()
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    let f = max(0, min(1, v.location.x / max(1, g.size.width)))
                    var nv = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    if step > 0 { nv = (nv / step).rounded() * step }
                    nv = max(range.lowerBound, min(range.upperBound, nv))
                    if nv != value {
                        value = nv
                        if step > 0 { UISelectionFeedbackGenerator().selectionChanged() }
                    }
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 44)
        .animation(.interactiveSpring(response: 0.2), value: value)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(label(value))
        .accessibilityAdjustableAction { dir in
            let st = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
            value = max(range.lowerBound, min(range.upperBound, value + (dir == .increment ? st : -st)))
        }
    }
}
