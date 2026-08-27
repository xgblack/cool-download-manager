import SwiftUI
import CoolDownloadCore

struct PerHostSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var state: PerHostSettingsViewState
    @State private var isSaving = false

    init(store: AppStore, state: PerHostSettingsViewState) {
        self.store = store
        self.state = state
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                hostList
                    .frame(width: 240)
                Divider()
                editor
            }
            Divider()
            HStack(spacing: 12) {
                if let error = state.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(isSaving ? "保存中…" : "保存") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !state.isDirty {
                state.replaceItems(store.perHostSettings)
            }
        }
        .onChange(of: store.perHostSettings) { items in
            if !state.isDirty { state.replaceItems(items) }
        }
        .onChange(of: state.selectedHost) { _ in
            state.selectionChanged()
        }
        .alert("操作失败", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "未知错误")
        }
    }

    private var hostList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("主机")
                    .font(.headline)
                Spacer()
                Text("\(state.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()
            List(selection: $state.selectedHost) {
                ForEach(state.items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.blue)
                            .frame(width: 18)
                        Text(item.host.isEmpty ? "新主机" : item.host)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(Optional(item.id))
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 12) {
                Button {
                    state.commitDraft()
                    state.addNew()
                } label: {
                    Image(systemName: "plus")
                }
                .help("新增主机设置")
                Spacer()
                Button {
                    state.commitDraft()
                    state.removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .help("删除主机设置")
                .disabled(state.selectedHost == nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(.bar)
        }
        .background(.regularMaterial)
    }

    private func save() {
        state.commitDraft()
        isSaving = true
        Task { @MainActor in
            if await store.savePerHostSettings(state.items) {
                state.markSaved()
            }
            isSaving = false
        }
    }

    @ViewBuilder
    private var editor: some View {
        if state.selectedHost != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("主机覆盖")
                        .font(.system(size: 28, weight: .bold))
                        .accessibilityAddTraits(.isHeader)

                    NativeSettingsGroup(title: "连接") {
                        PerHostSettingsRow(title: "主机") {
                            TextField("example.com 或 *.example.com", text: $state.host)
                                .textFieldStyle(.roundedBorder)
                        }
                        PerHostSettingsRow(title: "用户名") {
                            TextField("可选", text: $state.username)
                                .textFieldStyle(.roundedBorder)
                        }
                        PerHostSettingsRow(title: "密码") {
                            SecureField("可选", text: $state.password)
                                .textFieldStyle(.roundedBorder)
                        }
                        PerHostSettingsRow(title: "客户端标识 User-Agent", showsDivider: false) {
                            TextField("留空使用全局设置", text: $state.userAgent)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    NativeSettingsGroup(title: "下载") {
                        PerHostSettingsRow(title: "线程数") {
                            HStack {
                                Spacer()
                                TextField("留空使用全局设置", text: $state.threadCount)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .frame(width: 180)
                            }
                        }
                        PerHostSettingsRow(title: "速度限制（字节/秒）", showsDivider: false) {
                            HStack {
                                Spacer()
                                TextField("0 表示不限", text: $state.speedLimit)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .frame(width: 180)
                            }
                        }
                    }

                    Text("精确主机优先于通配符；留空字段沿用全局设置。密码只保存在本地配置中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: 720, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("选择一个主机设置")
                    .font(.headline)
                Text("也可以新建主机设置")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PerHostSettingsRow<Content: View>: View {
    let title: String
    let showsDivider: Bool
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        showsDivider: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.showsDivider = showsDivider
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider().padding(.leading, 14)
            }
        }
    }
}

@MainActor
final class PerHostSettingsViewState: ObservableObject {
    @Published var items: [PerHostSettingsItem]
    @Published var selectedHost: String?
    @Published var host = ""
    @Published var username = ""
    @Published var password = ""
    @Published var userAgent = ""
    @Published var threadCount = ""
    @Published var speedLimit = ""
    @Published var errorMessage: String?
    private var savedItems: [PerHostSettingsItem]

    init(items: [PerHostSettingsItem]) {
        self.items = items
        self.savedItems = items
        self.selectedHost = items.first?.id
        loadDraft()
    }

    var isDirty: Bool {
        // With no selected host there is no editable draft. Comparing the
        // empty draft value with `nil` would otherwise make every fresh
        // settings window look unsaved.
        guard selectedHost != nil else { return items != savedItems }
        return items != savedItems || draft != currentItem
    }

    func replaceItems(_ values: [PerHostSettingsItem]) {
        items = values
        savedItems = values
        selectedHost = values.first?.id
        loadDraft()
    }

    func addNew() {
        let candidate = uniqueTemporaryHost()
        items.append(PerHostSettingsItem(host: candidate))
        selectedHost = candidate
        loadDraft()
    }

    func removeSelected() {
        guard let selectedHost else { return }
        items.removeAll { $0.id == selectedHost }
        self.selectedHost = items.first?.id
        loadDraft()
    }

    func commitDraft() {
        guard let selectedHost, let index = items.firstIndex(where: { $0.id == selectedHost }) else { return }
        var updated = draft
        let normalized = updated.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        updated.host = normalized
        items[index] = updated
        self.selectedHost = updated.id
        loadDraft()
    }

    func markSaved() {
        savedItems = items
    }

    func selectionChanged() {
        loadDraft()
    }

    private var currentItem: PerHostSettingsItem? {
        guard let selectedHost else { return nil }
        return items.first { $0.id == selectedHost }
    }

    private var draft: PerHostSettingsItem {
        PerHostSettingsItem(
            host: host,
            username: username.nilIfEmpty,
            password: password.nilIfEmpty,
            userAgent: userAgent.nilIfEmpty,
            threadCount: Int(threadCount),
            speedLimit: Int64(speedLimit)
        )
    }

    private func loadDraft() {
        guard let currentItem else {
            host = ""
            username = ""
            password = ""
            userAgent = ""
            threadCount = ""
            speedLimit = ""
            return
        }
        host = currentItem.host
        username = currentItem.username ?? ""
        password = currentItem.password ?? ""
        userAgent = currentItem.userAgent ?? ""
        threadCount = currentItem.threadCount.map(String.init) ?? ""
        speedLimit = currentItem.speedLimit.map(String.init) ?? ""
    }

    private func uniqueTemporaryHost() -> String {
        var index = 1
        while items.contains(where: { $0.host == "new-host-\(index)" }) { index += 1 }
        return "new-host-\(index)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
