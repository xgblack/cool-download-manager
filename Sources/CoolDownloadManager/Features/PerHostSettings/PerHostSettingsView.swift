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
            actionBar
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
            NativeSidebarHeader(
                title: "主机",
                count: state.items.count,
                systemImage: "server.rack",
                tint: .blue
            )
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
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
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
            NativePageContent(maxWidth: NativePageLayout.compactContentWidth) {
                NativeSettingsGroup(title: "连接") {
                    NativeSettingsFieldRow(
                        "主机",
                        text: $state.host,
                        placeholder: "example.com 或 *.example.com"
                    )
                    NativeSettingsFieldRow(
                        "用户名",
                        text: $state.username,
                        placeholder: "留空使用全局设置"
                    )
                    NativeSettingsRow(title: "密码") {
                        SecureField("留空使用全局设置", text: $state.password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 310)
                    }
                    NativeSettingsFieldRow(
                        "客户端标识",
                        text: $state.userAgent,
                        placeholder: "留空使用全局设置",
                        showsDivider: false
                    )
                }

                NativeSettingsGroup(title: "下载") {
                    NativeSettingsRow(title: "线程数") {
                        TextField("空=继承全局上限", text: $state.threadCount)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 160)
                            .help("显式主机值是连接上限；空值继承全局上限，自动任务仍会参考学习画像作为起始档位")
                    }
                    NativeSettingsRow(title: "速度限制（字节/秒）", showsDivider: false) {
                        TextField("字节/秒（空=全局，0=本地不限）", text: $state.speedLimit)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 160)
                            .help("空值继承全局设置；0 只取消主机本地上限，全局上限仍生效")
                    }
                }
            }
        } else {
            NativeEmptyState(
                systemImage: "server.rack",
                title: "选择一个主机设置",
                message: "也可以新建主机设置"
            )
        }
    }

    private var actionBar: some View {
        NativePageActionBar {
            if let error = state.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button(isSaving ? "保存中…" : "保存") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving)
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
