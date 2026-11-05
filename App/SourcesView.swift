import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var opml: UTType { UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml }
}

struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.opml, .xml] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct SourcesView: View {
    @EnvironmentObject var store: FeedStore
    @State private var showAdd = false
    @State private var editing: FeedSource?
    @State private var importing = false
    @State private var exporting = false
    @State private var message: String?

    var body: some View {
        List {
            ForEach(store.groups, id: \.self) { g in
                Section(g) {
                    ForEach(store.sources.filter { store.groupName($0) == g }) { s in
                        Button { editing = s } label: { row(s) }
                            .swipeActions {
                                Button(role: .destructive) { store.removeSource(s) } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                }
                .listRowBackground(Color.clear.background(.ultraThinMaterial))
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground())
        .navigationTitle("订阅")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button { importing = true } label: { Label("导入 OPML", systemImage: "square.and.arrow.down") }
                    Button { exporting = true } label: { Label("导出 OPML", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "arrow.up.arrow.down.circle") }
            }
        }
        .sheet(isPresented: $showAdd) { AddSourceView().environmentObject(store) }
        .sheet(item: $editing) { EditSourceView(source: $0).environmentObject(store) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.opml, .xml, .data]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: url) {
                let n = store.importOPML(d)
                message = "导入了 \(n) 个订阅源"
                Task { await store.refresh() }
            }
        }
        .fileExporter(isPresented: $exporting, document: OPMLDocument(text: store.exportOPML()), contentType: .opml, defaultFilename: "Hark订阅") { _ in }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        }
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
    }

    private func row(_ s: FeedSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).foregroundStyle(s.enabled ? .primary : .secondary)
                Text(s.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            let n = store.unreadCount(for: s)
            if n > 0 {
                Text("\(n)").font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .glass(in: Capsule(), tint: Color.accentColor.opacity(0.35))
            }
        }
    }
}

struct AddSourceView: View {
    @EnvironmentObject var store: FeedStore
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var group = ""
    @State private var candidates: [FeedDiscovery.Candidate] = []
    @State private var searching = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("网址或 RSS 地址", text: $input)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("分组（可选）", text: $group)
                } footer: {
                    Text("输入网站地址会自动寻找它的 RSS，比如 sspai.com，或 YouTube 频道页。")
                }
                if !store.groups.isEmpty {
                    Section("已有分组") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(store.groups, id: \.self) { g in
                                    Button(g) { group = g }.glassButton(prominent: group == g)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button { Task { await find() } } label: {
                        HStack { Text("查找订阅源"); Spacer(); if searching { ProgressView() } }
                    }
                    .disabled(input.isEmpty || searching)
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
                if !candidates.isEmpty {
                    Section("找到的订阅源，点一下添加") {
                        ForEach(candidates) { c in
                            Button { add(c) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title)
                                    Text(c.url).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func find() async {
        searching = true
        errorText = nil
        candidates = []
        do {
            candidates = try await FeedDiscovery.discover(input)
            if candidates.isEmpty { errorText = "没找到 RSS，可以直接粘贴 RSS 地址再试。" }
        } catch {
            errorText = error.localizedDescription
        }
        searching = false
    }

    private func add(_ c: FeedDiscovery.Candidate) {
        store.addSource(name: c.title, url: c.url, group: group.trimmingCharacters(in: .whitespaces))
        dismiss()
        Task { await store.refresh() }
    }
}

struct EditSourceView: View {
    @EnvironmentObject var store: FeedStore
    @Environment(\.dismiss) private var dismiss
    @State var source: FeedSource

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("名称", text: $source.name) }
                Section("地址") {
                    TextField("RSS 地址", text: $source.url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("分组") { TextField("分组", text: $source.group) }
                Section { Toggle("启用", isOn: $source.enabled) }
                Section {
                    Button("删除订阅源", role: .destructive) { store.removeSource(source); dismiss() }
                }
            }
            .navigationTitle("编辑订阅源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { store.updateSource(source); dismiss(); Task { await store.refresh() } }
                }
            }
        }
    }
}
