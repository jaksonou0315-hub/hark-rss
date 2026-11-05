import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: FeedStore
    @State private var newKeyword = ""
    @State private var newKind: FilterRule.Kind = .mute

    var body: some View {
        Form {
            Section {
                Toggle("新消息通知", isOn: $store.notify)
                Picker("后台刷新间隔", selection: $store.refreshMinutes) {
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("1 小时").tag(60)
                    Text("2 小时").tag(120)
                }
            } header: {
                Text("通知与刷新")
            } footer: {
                Text("不签名的 App 用不了苹果远程推送。这里用系统后台刷新检查新消息、发本地通知，实际时间由 iOS 决定。")
            }

            Section {
                ForEach(store.rules) { r in
                    HStack {
                        Image(systemName: r.kind == .mute ? "eye.slash" : "highlighter")
                            .foregroundStyle(r.kind == .mute ? Color.red : Color.orange)
                        Text(r.keyword)
                        Spacer()
                        Text(r.kind.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { store.rules.remove(atOffsets: $0) }
                HStack {
                    TextField("添加关键词", text: $newKeyword)
                    Picker("", selection: $newKind) {
                        ForEach(FilterRule.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Button { addRule() } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .buttonStyle(.plain)
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("关键词过滤")
            } footer: {
                Text("屏蔽：标题或内容含关键词的文章不显示。高亮：卡片用橙色玻璃标出。")
            }

            Section {
                Picker("自动清理旧文章", selection: $store.retentionDays) {
                    Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90); Text("永不").tag(0)
                }
                LabeledContent("图片缓存", value: ByteCountFormatter.string(fromByteCount: Int64(imageCache), countStyle: .file))
                LabeledContent("文章数据", value: ByteCountFormatter.string(fromByteCount: store.dataSize, countStyle: .file))
                Button("清空图片缓存") { URLCache.shared.removeAllCachedResponses(); imageCache = 0 }
            } header: {
                Text("存储")
            } footer: {
                Text("收藏和稍后读的文章不会被清理。图片缓存在本机，看过的图离线也能显示。")
            }

            Section {
                TextField(RSSHub.defaultInstance, text: $rsshub)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { RSSHub.instance = rsshub }
                    .onChange(of: rsshub) { v in RSSHub.instance = v }
            } header: {
                Text("RSSHub 实例")
            } footer: {
                Text("留空就用公共实例 rsshub.app。已添加的订阅地址不会自动跟着改。")
            }

            Section("数据") {
                if let d = store.lastRefresh {
                    LabeledContent("上次刷新", value: d.formatted(date: .omitted, time: .shortened))
                }
                LabeledContent("缓存文章", value: "\(store.items.count) 篇")
                LabeledContent("收藏", value: "\(store.starredIDs.count) 篇")
                Button("清除已读记录") { store.readIDs = [] }
                Button("清空文章缓存", role: .destructive) { store.clearCache() }
            }

            Section("关于") {
                LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
                Text("默认订阅 Hark 推送源，也能在「订阅」里添加任意 RSS、Atom 或 JSON Feed。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground())
        .navigationTitle("设置")
    }

    @State private var imageCache = URLCache.shared.currentDiskUsage
    @State private var rsshub = UserDefaults.standard.string(forKey: "rsshubInstance") ?? ""

    private func addRule() {
        store.rules.append(FilterRule(keyword: newKeyword.trimmingCharacters(in: .whitespaces), kind: newKind))
        newKeyword = ""
    }
}
