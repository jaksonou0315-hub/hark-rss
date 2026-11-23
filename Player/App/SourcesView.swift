import SwiftUI
import CoreImage.CIFilterBuiltins

struct BrowseTarget: Hashable {
    var source: MediaSource
    var dir: RemoteFile?
}

enum SourcesMode { case all, files, servers
    func includes(_ k: SourceKind) -> Bool {
        switch self {
        case .all: return true
        case .servers: return k.isMediaServer
        case .files: return !k.isMediaServer
        }
    }
    var title: String { switch self { case .all: return "浏览"; case .files: return "文件源"; case .servers: return "服务器" } }
}

struct SourcesView: View {
    var mode: SourcesMode = .all
    @EnvironmentObject var store: SourceStore
    @State private var editing: MediaSource?
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.sources.filter { mode.includes($0.kind) }) { s in
                            NavigationLink(value: BrowseTarget(source: s, dir: nil)) {
                                HStack(spacing: 14) {
                                    Image(systemName: s.kind.icon).font(.title2).foregroundStyle(s.kind.tint)
                                        .frame(width: 46, height: 46)
                                        .glass(in: Circle(), tint: s.kind.tint.opacity(0.25))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(s.name).font(.headline)
                                        Text(s.kind == .local ? "通过「文件」App 或电脑共享导入" : (s.host.isEmpty ? s.kind.title : s.host))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if !s.isLoggedIn {
                                        Text("未登录").font(.caption2).padding(.horizontal, 8).padding(.vertical, 4).glass(in: Capsule(), tint: .orange.opacity(0.4))
                                    }
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if s.kind != .local {
                                    Button { editing = s } label: { Label("编辑", systemImage: "pencil") }
                                    Button(role: .destructive) { store.remove(s) } label: { Label("删除", systemImage: "trash") }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(mode.title)
            .navigationDestination(for: BrowseTarget.self) { FolderView(target: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(SourceKind.allCases.filter { $0 != .local && mode.includes($0) }) { k in
                            Button { editing = MediaSource(kind: k, name: k.title) } label: { Label(k.title, systemImage: k.icon) }
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { SourceEditor(source: $0) }
        }
    }
}

struct FolderView: View {
    let target: BrowseTarget
    @EnvironmentObject var store: SourceStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var router: PlaybackRouter
    @State private var files: [RemoteFile] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showAll = false
    @State private var toast: String?
    @State private var pushDir: RemoteFile?
    @State private var opening: String?
    @ObservedObject private var favs = FolderFavorites.shared

    private var smart: Bool { currentSource.extra["smartFolders"] == "1" }
    private func smartItem(_ f: RemoteFile) -> LibraryItem? {
        guard smart, f.isDir else { return nil }
        let t = NameParser.parse(f.name, parents: []).title.lowercased()
        guard !t.isEmpty else { return nil }
        return library.items.first { $0.title.lowercased() == t || ($0.originalTitle ?? "").lowercased() == t }
            ?? library.items.first { it in it.files.contains { $0.sourceId == currentSource.id && $0.file.meta["folder"] != nil && $0.file.path.contains("/\(f.name)/") } }
    }

    private var visible: [RemoteFile] { showAll ? files : files.filter { $0.isDir || $0.isVideo } }
    private var posterMode: Bool { target.source.kind.isMediaServer && target.dir != nil && files.filter({ $0.posterURL != nil }).count > 3 }

    var body: some View {
        ZStack {
            AuroraBackground()
            if loading {
                ProgressView("加载中…")
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.orange)
                    Text(error).multilineTextAlignment(.center).font(.subheadline)
                    Button("重试") { Task { await load() } }.glassButton(prominent: true)
                }
                .padding(24).glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous)).padding()
            } else if posterMode {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 170), spacing: 14)], spacing: 18) {
                        ForEach(visible) { f in
                            cell(f) {
                                VStack(alignment: .leading, spacing: 5) {
                                    PosterImage(url: f.posterURL, title: f.name)
                                        .aspectRatio(2/3, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    Text(f.name).font(.caption.weight(.semibold)).lineLimit(1)
                                    if let y = f.year { Text(String(y)).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            .overlay(alignment: .topTrailing) { if f.isDir { starButton(f, grid: true) } }
                        }
                    }
                    .padding()
                }
            } else {
                List {
                    ForEach(visible) { f in
                        cell(f) {
                            HStack(spacing: 12) {
                                if let p = f.posterURL ?? smartItem(f)?.poster {
                                    PosterImage(url: p, title: "").frame(width: 40, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Image(systemName: f.isDir ? "folder.fill" : (f.isVideo ? "film" : (f.isSubtitle ? "captions.bubble" : "doc")))
                                        .font(.title3).foregroundStyle(f.isDir ? Color.blue : (f.isVideo ? Color.pink : Color.secondary))
                                        .frame(width: 40)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    if let it = smartItem(f) {
                                        Text(it.title).lineLimit(2)
                                        Text([it.year.map { String($0) }, it.isTV ? "剧集" : "电影"].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text(f.name).lineLimit(2)
                                        if !f.sizeText.isEmpty { Text(f.sizeText).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                if opening == f.id { Spacer(); ProgressView() }
                            }
                            .padding(.trailing, f.isDir ? 40 : 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .trailing) { if f.isDir { starButton(f, grid: false) } }
                        .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
            if let t = toast {
                VStack { Spacer(); Text(t).font(.footnote).padding(.horizontal, 16).padding(.vertical, 10).glass(in: Capsule()).padding(.bottom, 90) }
                    .task(id: t) { try? await Task.sleep(nanoseconds: 2_000_000_000); toast = nil }
            }
        }
        .navigationTitle(target.dir?.name ?? target.source.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { favs.toggle(target.source, target.dir); toast = favs.contains(target.source, target.dir) ? "已收藏，会显示在「文件源」" : "已取消收藏" } label: {
                        favs.contains(target.source, target.dir) ? Label("取消收藏此文件夹", systemImage: "star.slash") : Label("收藏此文件夹", systemImage: "star")
                    }
                    if let d = target.dir {
                        Button { library.addFolder(source: target.source, dir: d); toast = "已添加到媒体库，正在扫描" } label: { Label("将此文件夹添加到媒体库", systemImage: "rectangle.stack.badge.plus") }
                    }
                    Toggle(isOn: $showAll) { Label("显示全部文件", systemImage: "doc.on.doc") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await load() }
        .navigationDestination(item: $pushDir) { d in FolderView(target: BrowseTarget(source: target.source, dir: d)) }
    }

    /// 智能文件夹: a folder holding a single video plays it straight away.
    private func openSmart(_ f: RemoteFile) {
        guard opening == nil else { return }
        opening = f.id
        Task {
            defer { opening = nil }
            if let list = try? await store.provider(for: currentSource).list(f) {
                let vids = list.filter { $0.isVideo && !$0.name.lowercased().contains("sample") }
                if vids.count == 1, !list.contains(where: { $0.isDir }) {
                    router.play(PlayRequest(source: currentSource, file: vids[0], siblings: list))
                    return
                }
            }
            pushDir = f
        }
    }

    /// Always-visible star on folder rows/tiles: one tap to 收藏 / 取消收藏.
    private func starButton(_ f: RemoteFile, grid: Bool) -> some View {
        let on = favs.contains(target.source, f)
        return Button {
            favs.toggle(target.source, f)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            toast = favs.contains(target.source, f) ? "已收藏，会显示在「文件源」" : "已取消收藏"
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(grid ? .subheadline.weight(.semibold) : .body)
                .foregroundStyle(on ? Color.yellow : (grid ? Color.white : Color.secondary))
                .frame(width: 44, height: 44)
                .background { if grid { Circle().fill(.black.opacity(0.35)).frame(width: 30, height: 30) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(on ? "取消收藏" : "收藏")
    }

    private func favButton(_ f: RemoteFile) -> some View {
        Button { favs.toggle(target.source, f); toast = favs.contains(target.source, f) ? "已收藏，会显示在「文件源」" : "已取消收藏" } label: {
            favs.contains(target.source, f) ? Label("取消收藏", systemImage: "star.slash") : Label("收藏", systemImage: "star")
        }
    }

    @ViewBuilder
    private func cell<L: View>(_ f: RemoteFile, @ViewBuilder label: () -> L) -> some View {
        if f.isDir && smart {
            Button { openSmart(f) } label: { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .contextMenu {
                    favButton(f)
                    Button { pushDir = f } label: { Label("打开文件夹", systemImage: "folder") }
                    Button { library.addFolder(source: target.source, dir: f); toast = "已添加到媒体库，正在扫描" } label: { Label("添加到媒体库", systemImage: "rectangle.stack.badge.plus") }
                }
        } else if f.isDir {
            NavigationLink(value: BrowseTarget(source: target.source, dir: f)) { label() }
                .buttonStyle(.plain)
                .contextMenu {
                    favButton(f)
                    Button { library.addFolder(source: target.source, dir: f); toast = "已添加到媒体库，正在扫描" } label: { Label("添加到媒体库", systemImage: "rectangle.stack.badge.plus") }
                }
        } else {
            Button {
                if f.isVideo {
                    router.play(PlayRequest(source: currentSource, file: f, siblings: files))
                }
            } label: { label() }
            .buttonStyle(.plain)
            .contextMenu {
                if f.isVideo {
                    Button { library.addFolder(source: target.source, dir: f); toast = "已添加到媒体库，正在扫描" } label: { Label("添加到媒体库", systemImage: "rectangle.stack.badge.plus") }
                }
            }
        }
    }

    private var currentSource: MediaSource { store.source(target.source.id) ?? target.source }

    private func load() async {
        loading = files.isEmpty
        error = nil
        do {
            files = try await ScanCenter.shared.browse(currentSource, target.dir)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Editor

struct SourceEditor: View {
    @State var source: MediaSource
    @EnvironmentObject var store: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?
    @State private var showLogin = false
    @State private var smsSent = false
    @State private var smsBusy = false
    @State private var smsCode = ""
    @State private var verificationId = ""
    @State private var showWebLogin = false
    @State private var showAdvanced = false

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { source.extra[key] ?? "" }, set: { source.extra[key] = $0 })
    }
    /// Toggle stored in extra as "1"/"0" with a default.
    private func flag(_ key: String, _ def: Bool) -> Binding<Bool> {
        Binding(get: { source.extra[key].map { $0 == "1" } ?? def }, set: { source.extra[key] = $0 ? "1" : "0" })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("名称", text: $source.name) }
                switch source.kind {
                case .smb:
                    Section {
                        TextField("主机，如 192.168.1.10", text: $source.host).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("用户名（留空为访客）", text: $source.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("密码", text: $source.password)
                        TextField("域（可选）", text: binding("domain")).textInputAutocapitalization(.never)
                    } header: { Text("SMB") } footer: { Text("支持 SMB2/3，可浏览共享并直接播放。") }
                case .webdav:
                    Section {
                        TextField("地址，如 https://nas.local:5006/dav", text: $source.host).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("用户名", text: $source.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("密码", text: $source.password)
                    } header: { Text("WebDAV") } footer: { Text("同样适用于 Alist、群晖、坚果云等 WebDAV 服务。") }
                case .emby, .jellyfin:
                    Section {
                        TextField("服务器地址，如 http://192.168.1.10:8096", text: $source.host).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("用户名", text: $source.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("密码", text: $source.password)
                    } header: { Text(source.kind.title) }
                case .aliyun:
                    Section {
                        TextField("client_id", text: binding("clientId")).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("client_secret", text: binding("clientSecret"))
                    } header: { Text("阿里云盘开放平台") } footer: {
                        Text("阿里云盘官方开放平台需要开发者自行申请应用（open.alipan.com）获得 client_id/secret，填好后点「扫码登录」。")
                    }
                    Section {
                        SecureField("refresh_token", text: $source.refreshToken)
                        TextField("令牌刷新地址（可选，Alist 方式）", text: binding("refreshURL")).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("或：手动填写令牌") } footer: {
                        Text("如果你已通过 Alist 等工具获得开放平台 refresh_token，可直接粘贴，并填写对应的刷新接口地址。")
                    }
                case .pan115:
                    Section {
                        SecureField("Cookie（扫码后自动填写）", text: binding("cookie"))
                    } header: { Text("115 网盘") } footer: {
                        Text("使用 115 App 扫码登录（非官方接口，实验性）。登录后会以独立设备身份登录，不影响网页端。")
                    }
                case .baidu:
                    Section {
                        TextField("AppKey", text: binding("appKey")).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("SecretKey", text: binding("secretKey"))
                    } header: { Text("百度网盘开放平台") } footer: {
                        Text("需要在 pan.baidu.com/union 申请应用，获得 AppKey / SecretKey 后点「扫码登录」。播放需在百度网盘端允许下载。")
                    }
                case .quark:
                    Section {
                        Picker("播放线路", selection: binding("linkMode")) {
                            Text("原画（下载直链）").tag("")
                            Text("转码（夸克在线播放）").tag("streaming")
                        }
                    } header: { Text("夸克网盘") } footer: {
                        Text("用夸克 App 扫码登录（TV 端授权，非官方接口）。原画画质最好；非会员原画可能限速，卡顿时换成「转码」。")
                    }
                case .guangya:
                    Section {
                        TextField("手机号，如 13800000000", text: binding("phone")).keyboardType(.phonePad)
                        Button {
                            Task { await sendGuangyaSMS() }
                        } label: { HStack { Label(smsSent ? "重新发送验证码" : "发送验证码", systemImage: "message"); if smsBusy { Spacer(); ProgressView() } } }
                        .disabled((source.extra["phone"] ?? "").trimmed.isEmpty || smsBusy)
                        if smsSent {
                            TextField("短信验证码", text: $smsCode).keyboardType(.numberPad)
                            Button { Task { await guangyaSignIn() } } label: { Label("登录", systemImage: "person.badge.key") }
                                .disabled(smsCode.trimmed.isEmpty || smsBusy)
                        }
                        if source.isLoggedIn { Label("已登录", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                    } header: { Text("光鸭云盘 · 短信登录") } footer: {
                        Text("非官方接口，与 OpenList 光鸭驱动同一方式。登录后令牌会自动续期。")
                    }
                    Section {
                        Picker("播放线路", selection: binding("linkMode")) {
                            Text("视频点播（推荐）").tag("")
                            Text("下载直链").tag("download")
                        }
                    } footer: { Text("光鸭的普通下载直链可能被限速；点播线路拿不到时会自动退回下载直链。") }
                    Section {
                        SecureField("refresh_token", text: $source.refreshToken)
                        TextField("client_id（留空用默认）", text: binding("clientId")).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("或：手动填写令牌") } footer: {
                        Text("短信触发人机验证时，可在电脑浏览器登录光鸭网页版，用「光鸭凭证获取」脚本复制 refresh_token 粘贴到这里。")
                    }
                case .pan123, .pcloud:
                    Section {
                        TextField(source.kind == .pan123 ? "手机号或邮箱" : "邮箱", text: $source.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                        SecureField("密码", text: $source.password)
                        if source.isLoggedIn { Label("已登录", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                    } header: { Text(source.kind.title) } footer: {
                        Text(source.kind == .pan123 ? "使用 123 云盘账号密码登录（网页端接口，与 OpenList 相同方式）。点「保存」时登录。"
                                                    : "使用 pCloud 账号密码登录，自动识别美国 / 欧洲数据中心。开了两步验证的账号暂不支持。")
                    }
                case .onedrive, .dropbox, .yandex:
                    Section {
                        Button { showWebLogin = true } label: {
                            Label(source.isLoggedIn ? "重新登录" : "登录 \(source.kind.title)", systemImage: "person.badge.key")
                        }
                        if source.isLoggedIn { Label("已登录", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                    } header: { Text(source.kind.title) } footer: {
                        Text("通过 OpenList 令牌服务（api.oplist.org）授权，无需自己申请开发者应用。授权只读取文件列表和播放地址，令牌只保存在本机。")
                    }
                    Section {
                        SecureField("refresh_token", text: $source.refreshToken)
                    } header: { Text("或：手动填写令牌") } footer: {
                        Text("也可以在电脑浏览器打开 api.oplist.org 获取 refresh_token 后粘贴到这里。")
                    }
                case .box:
                    Section {
                        TextField("Client ID", text: binding("clientId")).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Client Secret", text: binding("clientSecret"))
                        Button { showWebLogin = true } label: {
                            Label(source.isLoggedIn ? "重新登录" : "登录 Box", systemImage: "person.badge.key")
                        }
                        .disabled((source.extra["clientId"] ?? "").trimmed.isEmpty || (source.extra["clientSecret"] ?? "").trimmed.isEmpty)
                        if source.isLoggedIn { Label("已登录", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                    } header: { Text("Box") } footer: {
                        Text("在 app.box.com/developers/console 新建「Custom App › User Authentication (OAuth 2.0)」，Redirect URI 填 http://localhost，再把 Client ID / Secret 填到这里。")
                    }
                case .local:
                    EmptyView()
                }

                if source.kind != .local {
                    Section {
                        DisclosureGroup("高级", isExpanded: $showAdvanced) {
                            Toggle("自动扫描", isOn: flag("autoScan", true))
                            Toggle("预获取文件详情", isOn: flag("prefetch", true))
                            Toggle("预缓存海报", isOn: flag("posterCache", true))
                            Toggle("智能文件夹", isOn: flag("smartFolders", false))
                        }
                    } footer: {
                        if showAdvanced {
                            Text("自动扫描：保存后把整个网盘加入媒体库并扫描。预获取文件详情：扫描时就下载类型、分级、国家等资料。预缓存海报：扫描后提前下载海报，浏览更快。智能文件夹：浏览时用海报和片名显示影片文件夹，只有一个视频的文件夹点一下直接播放。")
                        }
                    }
                }

                if source.kind.needsQRLogin {
                    Section {
                        Button { showLogin = true } label: { Label(source.isLoggedIn ? "重新扫码登录" : "扫码登录", systemImage: "qrcode.viewfinder") }
                            .disabled(!canStartQR)
                        if source.isLoggedIn { Label("已登录", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                    }
                }
                if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle(source.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("保存") { Task { await save() } }.disabled(source.name.isEmpty) }
                }
            }
            .onAppear {
                if (source.kind == .quark || source.kind == .guangya), (source.extra["deviceId"] ?? "").count != 32 {
                    source.extra["deviceId"] = Hash.randomHex32()
                }
            }
            .sheet(isPresented: $showWebLogin) {
                OAuthLoginSheet(source: source) { updated in source = updated; message = "登录成功" }
            }
            .sheet(isPresented: $showLogin) {
                QRLoginView(source: source) { updated in source = updated; store.upsert(updated) }
            }
        }
    }

    private var canStartQR: Bool {
        switch source.kind {
        case .aliyun: return !(source.extra["clientId"] ?? "").isEmpty && !(source.extra["clientSecret"] ?? "").isEmpty
        case .baidu: return !(source.extra["appKey"] ?? "").isEmpty && !(source.extra["secretKey"] ?? "").isEmpty
        default: return true
        }
    }

    private func sendGuangyaSMS() async {
        smsBusy = true
        defer { smsBusy = false }
        do {
            verificationId = try await GuangyaProvider.sendSMS(source, phone: source.extra["phone"] ?? "")
            smsSent = true
            message = "验证码已发送"
        } catch { message = "发送失败：\(error.localizedDescription)" }
    }

    private func guangyaSignIn() async {
        smsBusy = true
        defer { smsBusy = false }
        do {
            source = try await GuangyaProvider.signIn(source, phone: source.extra["phone"] ?? "", code: smsCode.trimmed, verificationId: verificationId)
            store.upsert(source)
            message = "登录成功"
            smsSent = false
            smsCode = ""
        } catch { message = "登录失败：\(error.localizedDescription)" }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        if source.kind.isMediaServer {
            do {
                source = try await EmbyProvider.login(source)
            } catch {
                message = "登录失败：\(error.localizedDescription)"
                return
            }
        }
        if source.kind.needsPasswordLogin {
            do {
                source.token = ""
                source = source.kind == .pan123 ? try await Pan123Provider.login(source) : try await PCloudProvider.login(source)
            } catch {
                message = error.localizedDescription
                return
            }
        }
        let isNew = store.source(source.id) == nil
        store.upsert(source)
        if source.kind != .local, source.extra["autoScan"] != "0", source.isLoggedIn,
           isNew || !LibraryStore.shared.folders.contains(where: { $0.sourceId == source.id }) {
            LibraryStore.shared.addRoot(source: source)
        }
        dismiss()
    }
}

// MARK: - QR login

struct QRLoginView: View {
    let source: MediaSource
    var onDone: (MediaSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var qrText: String?
    @State private var qrImageURL: URL?
    @State private var qrData: Data?
    @State private var userCode: String?
    @State private var status = "正在获取二维码…"
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Group {
                    if let qrText, let img = Self.qr(qrText) {
                        Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    } else if let qrData, let img = UIImage(data: qrData) {
                        Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    } else if let qrImageURL {
                        AsyncImage(url: qrImageURL) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 240, height: 240)
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if let userCode {
                    Text("授权码：\(userCode)").font(.title3.monospaced().bold()).textSelection(.enabled)
                }
                Text(status).font(.subheadline).foregroundStyle(failed ? Color.red : Color.secondary).multilineTextAlignment(.center)
                if failed { Button("重试") { Task { await run() } }.glassButton(prominent: true) }
                Spacer()
            }
            .padding()
            .navigationTitle("\(source.kind.title) 扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await run() }
        }
    }

    static func qr(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func run() async {
        failed = false
        do {
            switch source.kind {
            case .aliyun: try await aliyun()
            case .pan115: try await pan115()
            case .baidu: try await baidu()
            case .quark: try await quark()
            default: break
            }
        } catch is CancellationError {
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }

    private func finish(_ s: MediaSource) { onDone(s); status = "登录成功"; dismiss() }

    private func aliyun() async throws {
        let (url, sid) = try await AliyunProvider.startQR(clientId: source.extra["clientId"] ?? "", clientSecret: source.extra["clientSecret"] ?? "")
        qrImageURL = URL(string: url)
        status = "请使用阿里云盘 App 扫码"
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let r = try await AliyunProvider.pollQR(sid: sid)
            switch r.status {
            case "ScanSuccess": status = "已扫码，请在手机上确认"
            case "LoginSuccess":
                if let code = r.authCode { finish(try await AliyunProvider.exchange(source, code: code)); return }
            case "QRCodeExpired": throw AppError.message("二维码已过期")
            default: break
            }
        }
    }

    private func pan115() async throws {
        let t = try await Pan115Provider.startQR()
        qrText = t.qr
        status = "请使用 115 App 扫码"
        while !Task.isCancelled {
            let st = try await Pan115Provider.pollQR(uid: t.uid, time: t.time, sign: t.sign)
            switch st {
            case 1: status = "已扫码，请在手机上确认"
            case 2:
                let cookie = try await Pan115Provider.finishQR(uid: t.uid)
                var s = source
                s.extra["cookie"] = cookie
                finish(s)
                return
            case -1: throw AppError.message("二维码已过期")
            case -2: throw AppError.message("已取消登录")
            default: try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func quark() async throws {
        var s = source
        if (s.extra["deviceId"] ?? "").count != 32 { s.extra["deviceId"] = Hash.randomHex32() }
        let did = s.extra["deviceId"] ?? ""
        let q = try await QuarkTVProvider.startQR(deviceId: did)
        if let img = q.image { qrData = img } else { qrText = q.text }
        status = "请使用夸克 App 扫码并确认授权"
        let deadline = Date().addingTimeInterval(300)
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if let code = await QuarkTVProvider.pollCode(queryToken: q.queryToken, deviceId: did) {
                finish(try await QuarkTVProvider.token(s, code: code))
                return
            }
            if Date() > deadline { throw AppError.message("二维码已过期") }
        }
    }

    private func baidu() async throws {
        let d = try await BaiduProvider.startDevice(appKey: source.extra["appKey"] ?? "")
        qrImageURL = URL(string: d.qrURL)
        userCode = d.userCode
        status = "用百度网盘 App 扫码，或在浏览器打开 \(d.verifyURL) 输入授权码"
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: UInt64(max(d.interval, 3)) * 1_000_000_000)
            if let s = try await BaiduProvider.pollDevice(source, code: d.deviceCode) { finish(s); return }
        }
    }
}
