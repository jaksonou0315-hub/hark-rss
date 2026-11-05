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

    private func addRule() {
        store.rules.append(FilterRule(keyword: newKeyword.trimmingCharacters(in: .whitespaces), kind: newKind))
        newKeyword = ""
    }
}
