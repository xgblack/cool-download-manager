import SwiftUI
import CoolDownloadCore

struct PerHostSettingsView: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @ObservedObject private var state: PerHostSettingsViewState

    init(store: AppStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        _state = ObservedObject(wrappedValue: PerHostSettingsViewState(items: store.perHostSettings))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("每主机设置", systemImage: "server.rack")
                    .font(.title3.weight(.semibold))
                Spacer()
                if state.isDirty {
                    Text("未保存").font(.caption).foregroundStyle(.orange)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(16)
            Divider()

            HStack(spacing: 0) {
                hostList
                    .frame(width: 230)
                Divider()
                editor
            }
            Divider()
            HStack {
                if let error = state.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button("保存") {
                    state.commitDraft()
                    store.savePerHostSettings(state.items)
                    state.markSaved()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!state.isDirty)
            }
            .padding(12)
        }
        .frame(width: 760, height: 520)
        .onAppear {
            state.replaceItems(store.perHostSettings)
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
            List(selection: $state.selectedHost) {
                ForEach(state.items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                        Text(item.host.isEmpty ? "新主机" : item.host)
                            .lineLimit(1)
                    }
                    .tag(Optional(item.id))
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
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
            .padding(10)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if state.selectedHost != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSectionView(title: "主机覆盖", description: "精确主机优先于带通配符的主机；留空字段沿用全局设置。") {
                        TextField("主机或通配符，例如 *.example.com", text: $state.host)
                        TextField("用户名（可选）", text: $state.username)
                        SecureField("密码（可选）", text: $state.password)
                        TextField("User-Agent（可选）", text: $state.userAgent)
                        HStack {
                            Text("线程数")
                            TextField("留空使用全局", text: $state.threadCount)
                                .frame(width: 130)
                        }
                        HStack {
                            Text("速度限制（字节/秒）")
                            TextField("0=不限，留空使用全局", text: $state.speedLimit)
                                .frame(width: 190)
                        }
                    }
                    Text("密码仅写入本地配置，不会出现在日志、URL 或浏览器扩展协议中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "server.rack").font(.system(size: 32)).foregroundStyle(.secondary)
                Text("选择一个主机设置").font(.headline)
                Text("或使用左下角加号新增").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
private final class PerHostSettingsViewState: ObservableObject {
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

    var isDirty: Bool { items != savedItems || draft != currentItem }

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
