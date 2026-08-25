import SwiftUI
import CoolDownloadCore

struct SettingsView: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    let onOpenPerHostSettings: () -> Void
    @ObservedObject private var viewState: SettingsViewState

    init(
        store: AppStore,
        onClose: @escaping () -> Void,
        onOpenPerHostSettings: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onClose = onClose
        self.onOpenPerHostSettings = onOpenPerHostSettings
        _viewState = ObservedObject(wrappedValue: SettingsViewState(model: store.settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("设置", systemImage: "gearshape")
                    .font(.title3.weight(.semibold))
                Spacer()
                if viewState.isDirty {
                    Text("未保存")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(18)

            Divider()

            HStack(spacing: 0) {
                List(selection: $viewState.section) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 170)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionContent
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            HStack {
                if let error = viewState.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("恢复默认", role: .destructive) {
                    viewState.model = AppSettingsModel.defaults()
                }
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(viewState.isSaving ? "保存中…" : "保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewState.isDirty || viewState.isSaving)
            }
            .padding(12)
        }
        .frame(width: 780, height: 600)
        .fileImporter(
            isPresented: $viewState.isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewState.model.defaultDownloadFolder = url.path
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch viewState.section {
        case .appearance:
            appearanceSection
        case .downloadEngine:
            downloadEngineSection
        case .browserIntegration:
            browserIntegrationSection
        }
    }

    private var appearanceSection: some View {
        SettingsSectionView(title: "外观", description: "控制主题、窗口、通知和信息显示方式。") {
            Picker("主题", selection: binding(\.theme)) {
                Text("深色").tag("dark")
                Text("浅色").tag("light")
                Text("跟随系统").tag("system")
            }
            TextField("默认深色主题", text: binding(\.defaultDarkTheme))
            TextField("默认浅色主题", text: binding(\.defaultLightTheme))
            TextField("语言（留空跟随系统）", text: optionalStringBinding(\.language))
            TextField("字体（留空使用系统字体）", text: optionalStringBinding(\.font))
            HStack {
                Text("UI 缩放")
                Slider(value: doubleBinding(\.uiScale, defaultValue: 1), in: 0.75...2, step: 0.05)
                Text(String(format: "%.0f%%", (viewState.model.uiScale ?? 1) * 100))
                    .frame(width: 48, alignment: .trailing)
            }
            Toggle("合并标题栏和顶部工具栏", isOn: binding(\.mergeTopBarWithTitleBar))
            Toggle("使用原生菜单栏", isOn: binding(\.useNativeMenuBar))
            Toggle("显示工具栏图标标签", isOn: binding(\.showIconLabels))
            Toggle("使用相对日期时间", isOn: binding(\.useRelativeDateTime))
            Toggle("使用菜单栏图标", isOn: binding(\.useSystemTray))

            Divider()
            Picker("文件大小单位", selection: binding(\.sizeUnit)) {
                Text("二进制（MiB）").tag("BinaryBytes")
                Text("十进制（MB）").tag("DecimalBytes")
            }
            Picker("速度单位", selection: binding(\.speedUnit)) {
                Text("二进制（MiB/s）").tag("BinaryBytes")
                Text("十进制（MB/s）").tag("DecimalBytes")
            }
            Toggle("显示平均速度", isOn: binding(\.useAverageSpeed))

            Divider()
            Toggle("启用通知声音", isOn: binding(\.notificationSound))
            if viewState.model.notificationSound {
                TextField("普通通知声音", text: binding(\.generalNotificationSound))
                TextField("错误通知声音", text: binding(\.errorNotificationSound))
                TextField("成功通知声音", text: binding(\.successNotificationSound))
            }
            Toggle("显示下载进度窗口", isOn: binding(\.showDownloadProgressDialog))
            if viewState.model.showDownloadProgressDialog {
                Toggle("下载开始时自动聚焦", isOn: binding(\.focusDownloadProgressDialogOnStart))
            }
            Toggle("显示下载完成窗口", isOn: binding(\.showDownloadCompletionDialog))
            if viewState.model.showDownloadCompletionDialog {
                Toggle("下载完成时自动聚焦", isOn: binding(\.focusDownloadCompletionDialogOnFinish))
            }
            Toggle("开机启动", isOn: binding(\.autoStartOnBoot))
        }
    }

    private var downloadEngineSection: some View {
        SettingsSectionView(title: "下载引擎", description: "控制保存位置、调度、网络和恢复行为。") {
            HStack {
                TextField("默认下载目录", text: binding(\.defaultDownloadFolder))
                Button("选择", systemImage: "folder") {
                    viewState.isFolderPickerPresented = true
                }
                .help("选择默认下载目录")
            }
            Toggle("默认使用分类", isOn: binding(\.useCategoryByDefault))
            TextField("全局速度限制（字节/秒，0=不限）", text: int64StringBinding(\.speedLimit))
            TextField("分段/线程数", text: intStringBinding(\.threadCount))
            TextField("最大并发下载数（0=不限）", text: intStringBinding(\.maxConcurrentDownloads))
            TextField("最大重试次数", text: intStringBinding(\.maxDownloadRetryCount))
            Toggle("动态创建分段", isOn: binding(\.dynamicPartCreation))
            Button("每主机设置", systemImage: "server.rack") {
                onOpenPerHostSettings()
            }
            .buttonStyle(.borderless)

            Divider()
            Picker("代理", selection: binding(\.proxyMode)) {
                Text("系统代理").tag("system")
                Text("直连").tag("direct")
                Text("手动代理").tag("manual")
                Text("PAC").tag("pac")
            }
            if viewState.model.proxyMode == "manual" {
                TextField("代理主机", text: binding(\.proxyHost))
                TextField("代理端口", text: intStringBinding(\.proxyPort))
                TextField("代理用户名", text: binding(\.proxyUsername))
                SecureField("代理密码", text: binding(\.proxyPassword))
            } else if viewState.model.proxyMode == "pac" {
                TextField("PAC URL", text: binding(\.proxyPACURL))
            }
            TextField("DNS 服务器（逗号分隔）", text: dnsBinding)
            TextField("默认 User-Agent", text: binding(\.userAgent))
            Toggle("忽略 SSL 证书错误", isOn: binding(\.ignoreSSLCertificates))
            Toggle("使用服务器 Last-Modified", isOn: binding(\.useServerLastModifiedTime))

            Divider()
            Toggle("跟踪磁盘上被删除的文件", isOn: binding(\.trackDeletedFilesOnDisk))
            Toggle("取消时删除临时文件", isOn: binding(\.deletePartialFileOnDownloadCancellation))
            Toggle("使用稀疏文件分配", isOn: binding(\.useSparseFileAllocation))
            Toggle("给未完成文件追加扩展名", isOn: binding(\.appendExtensionToIncompleteDownloads))
        }
    }

    private var browserIntegrationSection: some View {
        SettingsSectionView(title: "浏览器集成", description: "保留现有扩展的 loopback HTTP 和 Native Messaging 兼容协议。") {
            Toggle("启用浏览器集成 API", isOn: binding(\.apiEnabled))
            TextField("API 端口", text: intStringBinding(\.apiPort))
                .disabled(!viewState.model.apiEnabled)
            Toggle("启用 API 鉴权", isOn: binding(\.apiAuthEnabled))
                .disabled(!viewState.model.apiEnabled)
            HStack {
                SecureField("API key", text: binding(\.apiAuthKey))
                    .disabled(!viewState.model.apiEnabled || !viewState.model.apiAuthEnabled)
                Button("重新生成") {
                    viewState.model.apiAuthKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                }
                .disabled(!viewState.model.apiEnabled || !viewState.model.apiAuthEnabled)
            }
            Text("Native Messaging 使用私有 Unix socket，不复用 API key；关闭 HTTP API 不会关闭扩展的 Native Messaging fallback。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        viewState.isSaving = true
        viewState.errorMessage = nil
        Task { @MainActor in
            let success = await store.saveSettings(viewState.model)
            if success {
                viewState.isSaving = false
                viewState.markSaved(store.settings)
                onClose()
            } else {
                viewState.errorMessage = store.errorMessage ?? "设置保存失败"
            }
            viewState.isSaving = false
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettingsModel, T>) -> Binding<T> {
        Binding(
            get: { viewState.model[keyPath: keyPath] },
            set: { viewState.model[keyPath: keyPath] = $0 }
        )
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<AppSettingsModel, String?>) -> Binding<String> {
        Binding(
            get: { viewState.model[keyPath: keyPath] ?? "" },
            set: { viewState.model[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func intStringBinding(_ keyPath: WritableKeyPath<AppSettingsModel, Int>) -> Binding<String> {
        Binding(
            get: { String(viewState.model[keyPath: keyPath]) },
            set: { viewState.model[keyPath: keyPath] = Int($0) ?? viewState.model[keyPath: keyPath] }
        )
    }

    private func int64StringBinding(_ keyPath: WritableKeyPath<AppSettingsModel, Int64>) -> Binding<String> {
        Binding(
            get: { String(viewState.model[keyPath: keyPath]) },
            set: { viewState.model[keyPath: keyPath] = Int64($0) ?? viewState.model[keyPath: keyPath] }
        )
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<AppSettingsModel, Double?>, defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { viewState.model[keyPath: keyPath] ?? defaultValue },
            set: { viewState.model[keyPath: keyPath] = $0 }
        )
    }

    private var dnsBinding: Binding<String> {
        Binding(
            get: { viewState.model.dnsServers.joined(separator: ", ") },
            set: { viewState.model.dnsServers = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        )
    }
}

enum SettingsSection: String, CaseIterable, Hashable {
    case appearance
    case downloadEngine
    case browserIntegration

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .downloadEngine: return "下载引擎"
        case .browserIntegration: return "浏览器集成"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintbrush"
        case .downloadEngine: return "arrow.down.circle"
        case .browserIntegration: return "network"
        }
    }
}

@MainActor
final class SettingsViewState: ObservableObject {
    @Published var model: AppSettingsModel
    @Published var section: SettingsSection = .appearance
    @Published var isFolderPickerPresented = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    private var savedModel: AppSettingsModel

    init(model: AppSettingsModel) {
        self.model = model
        self.savedModel = model
    }

    var isDirty: Bool { model != savedModel }

    func markSaved(_ model: AppSettingsModel) {
        self.model = model
        savedModel = model
    }
}

struct SettingsSectionView<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }
}
