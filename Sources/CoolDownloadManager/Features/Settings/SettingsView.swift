import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoolDownloadCore

/// Native macOS preferences surface. The `Settings` scene supplies the
/// standard window chrome; this view only owns the preference content.
struct SettingsView: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    let onOpenPerHostSettings: () -> Void
    @StateObject private var viewState: SettingsViewState
    @StateObject private var windowGuard = SettingsWindowGuard()

    init(
        store: AppStore,
        onClose: @escaping () -> Void = {},
        onOpenPerHostSettings: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onClose = onClose
        self.onOpenPerHostSettings = onOpenPerHostSettings
        _viewState = StateObject(wrappedValue: SettingsViewState(model: store.settings))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $viewState.section) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("设置")
            .frame(minWidth: 190)
        } detail: {
            Form {
                sectionContent
            }
            .formStyle(.grouped)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if viewState.isDirty {
                        Text("未保存")
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button("恢复默认") {
                        viewState.model = AppSettingsModel.defaults()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewState.isSaving ? "保存中…" : "保存") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewState.isDirty || viewState.isSaving)
                }
            }
        }
        .frame(minWidth: 790, minHeight: 560)
        .background {
            WindowAccessor { window in
                windowGuard.attach(window, isDirty: {
                    viewState.isDirty
                }, discard: {
                    viewState.markSaved(store.settings)
                }
                )
            }
        }
        .fileImporter(
            isPresented: $viewState.isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewState.model.defaultDownloadFolder = url.path
            }
        }
        .alert("设置保存失败", isPresented: Binding(
            get: { viewState.errorMessage != nil },
            set: { if !$0 { viewState.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewState.errorMessage ?? "")
        }
        .onChange(of: store.settings) { updated in
            guard !viewState.isDirty, !viewState.isSaving else { return }
            viewState.markSaved(updated)
        }
        .onAppear {
            store.refreshAutoStartStatus()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch viewState.section {
        case .general:
            generalSection
        case .downloads:
            downloadsSection
        case .network:
            networkSection
        case .browserIntegration:
            browserIntegrationSection
        case .advanced:
            advancedSection
        }
    }

    private var generalSection: some View {
        Group {
            Section {
                Picker("外观", selection: binding(\.theme)) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                TextField("字体", text: optionalStringBinding(\.font))
                HStack {
                    Text("界面缩放")
                    Slider(value: doubleBinding(\.uiScale, defaultValue: 1), in: 0.75...2, step: 0.05)
                    Text(String(format: "%.0f%%", (viewState.model.uiScale ?? 1) * 100))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            } header: {
                Text("外观")
            } footer: {
                Text("字体使用已安装的 macOS 字体名称；留空使用系统字体。")
            }

            Section {
                Toggle("合并标题栏和顶部工具栏", isOn: binding(\.mergeTopBarWithTitleBar))
                Toggle("显示工具栏图标标签", isOn: binding(\.showIconLabels))
                Toggle("使用相对日期时间", isOn: binding(\.useRelativeDateTime))
                Toggle("使用菜单栏图标", isOn: binding(\.useSystemTray))
                LabeledContent("菜单栏") {
                    Text("macOS 原生")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("窗口与菜单栏")
            } footer: {
                Text("这是原生 macOS 应用，系统菜单栏始终启用；旧版开关仅保留用于兼容配置。")
            }

            Section("单位") {
                Picker("文件大小", selection: binding(\.sizeUnit)) {
                    Text("二进制（KiB、MiB）").tag("BinaryBytes")
                    Text("十进制（kB、MB）").tag("DecimalBytes")
                }
                Picker("传输速度", selection: binding(\.speedUnit)) {
                    Text("二进制（MiB/s）").tag("BinaryBytes")
                    Text("十进制（MB/s）").tag("DecimalBytes")
                }
                Toggle("使用平均速度", isOn: binding(\.useAverageSpeed))
            }

            Section {
                Toggle("启用通知声音", isOn: binding(\.notificationSound))
                if viewState.model.notificationSound {
                    TextField("普通通知声音文件名", text: binding(\.generalNotificationSound))
                    TextField("错误通知声音文件名", text: binding(\.errorNotificationSound))
                    TextField("完成通知声音文件名", text: binding(\.successNotificationSound))
                }
                Toggle("显示下载进度窗口", isOn: binding(\.showDownloadProgressDialog))
                if viewState.model.showDownloadProgressDialog {
                    Toggle("下载开始时自动聚焦", isOn: binding(\.focusDownloadProgressDialogOnStart))
                }
                Toggle("显示下载完成窗口", isOn: binding(\.showDownloadCompletionDialog))
                if viewState.model.showDownloadCompletionDialog {
                    Toggle("下载完成时自动聚焦", isOn: binding(\.focusDownloadCompletionDialogOnFinish))
                }
            } header: {
                Text("通知与弹窗")
            } footer: {
                Text("完成通知优先使用完成声音；失败通知优先使用错误声音；留空时回退到普通声音。声音文件必须随 App 一起安装。")
            }

            Section {
                Toggle("开机启动", isOn: binding(\.autoStartOnBoot))
                LabeledContent("登录项状态") {
                    Text(store.autoStartStatusTitle)
                        .foregroundStyle(store.autoStartStatus == .enabled ? .green : .secondary)
                }
            } header: {
                Text("系统")
            } footer: {
                Text("开机启动通过 macOS 登录项注册，不会创建额外的后台进程。若显示“需要系统批准”，请到系统设置的登录项中允许此 App。")
            }
        }
    }

    private var downloadsSection: some View {
        Group {
            Section {
                HStack {
                    TextField("默认下载目录", text: binding(\.defaultDownloadFolder))
                    Button("选择…", systemImage: "folder") {
                        viewState.isFolderPickerPresented = true
                    }
                }
                Toggle("默认使用分类", isOn: binding(\.useCategoryByDefault))
            } header: {
                Text("保存位置")
            }

            Section("调度") {
                TextField("分段线程数", text: intStringBinding(\.threadCount))
                TextField("最大并发下载数（0 表示不限）", text: intStringBinding(\.maxConcurrentDownloads))
                TextField("最大重试次数", text: intStringBinding(\.maxDownloadRetryCount))
                TextField("全局速度限制（字节/秒，0 表示不限）", text: int64StringBinding(\.speedLimit))
                Toggle("动态创建分段", isOn: binding(\.dynamicPartCreation))
            }

            Section("文件与恢复") {
                Toggle("给未完成文件追加扩展名", isOn: binding(\.appendExtensionToIncompleteDownloads))
                Toggle("使用稀疏文件分配", isOn: binding(\.useSparseFileAllocation))
                Toggle("取消下载时删除临时文件", isOn: binding(\.deletePartialFileOnDownloadCancellation))
                Toggle("使用服务器 Last-Modified 时间", isOn: binding(\.useServerLastModifiedTime))
            }
        }
    }

    private var networkSection: some View {
        Group {
            Section {
                Picker("代理模式", selection: binding(\.proxyMode)) {
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
            } header: {
                Text("代理")
            }

            Section {
                TextField("User-Agent", text: binding(\.userAgent))
                Toggle("忽略 SSL 证书错误", isOn: binding(\.ignoreSSLCertificates))
                TextField("DNS 服务器（仅兼容保存）", text: dnsBinding)
            } header: {
                Text("连接")
            } footer: {
                Text("DNS 服务器设置会保留在兼容配置中；macOS URLSession 当前不支持单会话 DNS 覆盖。")
            }

            Section("每主机设置") {
                Button("管理每主机连接和限速…", systemImage: "server.rack", action: onOpenPerHostSettings)
            }
        }
    }

    private var browserIntegrationSection: some View {
        Group {
            Section {
                Toggle("启用浏览器集成 API", isOn: binding(\.apiEnabled))
                TextField("API 端口", text: intStringBinding(\.apiPort))
                    .disabled(!viewState.model.apiEnabled)
                Toggle("启用 API 鉴权", isOn: binding(\.apiAuthEnabled))
                    .disabled(!viewState.model.apiEnabled)
                HStack {
                    SecureField("API key", text: binding(\.apiAuthKey))
                        .disabled(!viewState.model.apiEnabled || !viewState.model.apiAuthEnabled)
                    Button("重新生成") {
                        viewState.model.apiAuthKey = UUID().uuidString
                            .replacingOccurrences(of: "-", with: "")
                            .lowercased()
                    }
                    .disabled(!viewState.model.apiEnabled || !viewState.model.apiAuthEnabled)
                }
            } header: {
                Text("Loopback API")
            } footer: {
                Text("默认监听 127.0.0.1。现有浏览器扩展仍使用 com.abdownloadmanager 兼容标识。")
            }

            Section("Native Messaging") {
                LabeledContent("状态") {
                    Text("随应用启动自动安装")
                        .foregroundStyle(.secondary)
                }
                Text("Native Messaging 使用私有 Unix socket，不复用 HTTP API key。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var advancedSection: some View {
        Group {
            Section {
                Toggle("跟踪磁盘上被删除的文件", isOn: binding(\.trackDeletedFilesOnDisk))
            } header: {
                Text("文件一致性")
            } footer: {
                Text("启用后，应用会定期检查已完成任务的目标文件；文件已从磁盘删除时，同时移除下载记录。")
            }

            Section {
                TextField("默认深色主题标识", text: binding(\.defaultDarkTheme))
                TextField("默认浅色主题标识", text: binding(\.defaultLightTheme))
                TextField("语言（留空跟随系统）", text: optionalStringBinding(\.language))
            } header: {
                Text("兼容性")
            } footer: {
                Text("这些字段保留旧版 .abdm 配置格式，macOS 原生界面当前使用系统语言和主题。")
            }
        }
    }

    private func save() {
        viewState.isSaving = true
        viewState.errorMessage = nil
        Task { @MainActor in
            let success = await store.saveSettings(viewState.model)
            if success {
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
            set: {
                viewState.model.dnsServers = $0
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

enum SettingsSection: String, CaseIterable, Hashable {
    case general
    case downloads
    case network
    case browserIntegration
    case advanced

    var title: String {
        switch self {
        case .general: return "通用"
        case .downloads: return "下载"
        case .network: return "网络"
        case .browserIntegration: return "浏览器集成"
        case .advanced: return "高级"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .downloads: return "arrow.down.circle"
        case .network: return "network"
        case .browserIntegration: return "globe"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

@MainActor
final class SettingsViewState: ObservableObject {
    @Published var model: AppSettingsModel
    @Published var section: SettingsSection = .general
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

@MainActor
private final class SettingsWindowGuard: NSObject, ObservableObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private var dirty: () -> Bool = { false }
    private var discard: () -> Void = {}

    func attach(
        _ window: NSWindow?,
        isDirty: @escaping () -> Bool,
        discard: @escaping () -> Void
    ) {
        guard let window else { return }
        self.window = window
        self.dirty = isDirty
        self.discard = discard
        if window.delegate !== self {
            window.delegate = self
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty() else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未保存的设置？"
        alert.informativeText = "关闭窗口后，尚未保存的更改将丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "放弃更改")
        alert.addButton(withTitle: "继续编辑")
        let shouldClose = alert.runModal() == .alertFirstButtonReturn
        if shouldClose {
            discard()
        }
        return shouldClose
    }
}

/// Shared heading used by the secondary per-host editor while the primary
/// settings surface uses native `Form` sections.
struct SettingsSectionView<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
