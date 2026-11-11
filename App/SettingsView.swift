import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: FeedStore
    @State private var newKeyword = ""
    @State private var newKind: FilterRule.Kind = .mute

    var body: some View {
        Form {
            Section {
                NavigationLink { ReaderSettingsForm().navigationTitle("阅读与列表") } label: {
                    Label("阅读与列表", systemImage: "textformat.size")
                }
            } footer: {
                Text("字号、行距、衬线字体、纸张或夜间主题、朗读速度，以及列表样式。")
            }

            Section {
                NavigationLink { TranslateSettingsForm().navigationTitle("阅读翻译") } label: {
                    Label("阅读翻译", systemImage: "character.bubble")
                }
            } footer: {
                Text("目标语言、系统翻译语言包下载、AI 翻译服务商和模型。")
            }

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
                Text("留空会自动在几个公共镜像间切换，哪个能用就用哪个。填了自建实例后，所有 RSSHub 订阅都走你的实例。微博需要自建实例并配置 Cookie。")
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

            Section {
                Label("“刷新 Hark 推送”", systemImage: "arrow.clockwise")
                Label("“Hark 推送有几条未读”", systemImage: "circle.inset.filled")
                Label("“用 Hark 推送添加订阅”", systemImage: "plus.circle")
            } header: {
                Text("Siri 与快捷指令")
            } footer: {
                Text("在「快捷指令」App 里也能找到这些动作。把「添加到 Hark 推送」做成分享菜单快捷指令，就能在 Safari 里一键订阅当前网站。收藏和稍后读的文章可以在系统搜索里搜到。")
            }

            Section("关于") {
                LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
                Text("串联看世界")
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
