import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoolDownloadCore

/// Native macOS preferences surface. The `Settings` scene supplies the
/// standard window chrome; this view only owns the preference content.
struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var coordinator: AppCoordinator
    let onOpenPerHostSettings: () -> Void
    @StateObject private var viewState: SettingsViewState
    @StateObject private var windowGuard = SettingsWindowGuard()

    init(
        store: AppStore,
        coordinator: AppCoordinator,
        onOpenPerHostSettings: @escaping () -> Void = {}
    ) {
        self.store = store
        self.coordinator = coordinator
        self.onOpenPerHostSettings = onOpenPerHostSettings
        _viewState = StateObject(wrappedValue: SettingsViewState(
            model: store.settings,
            perHostItems: store.perHostSettings
        ))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $viewState.columnVisibility) {
            List(selection: $viewState.section) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 190)
        } detail: {
            NavigationStack(path: $viewState.path) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(viewState.section.title)
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 24)
                        .padding(.top, 22)
                        .padding(.bottom, 4)
                    Form {
                        sectionContent
                    }
                    .formStyle(.grouped)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .perHost:
                        PerHostSettingsView(store: store, state: viewState.perHostState)
                            .navigationTitle("每主机设置")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewState.path.isEmpty {
                    HStack(spacing: 12) {
                        Spacer()
                        Button("恢复默认") {
                            viewState.model = AppSettingsModel.defaults()
                        }
                        Button(viewState.isSaving ? "保存中…" : "保存") {
                            save()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewState.isSaving)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.bar)
                }
            }
        }
        .frame(minWidth: 790, minHeight: 560)
        .preferredColorScheme(preferredColorScheme)
        .background {
            WindowAccessor { window in
                windowGuard.attach(window, isDirty: {
                    viewState.isDirty
                }, discard: {
                    viewState.markSaved(store.settings, perHostItems: store.perHostSettings)
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
            viewState.markSaved(updated, perHostItems: store.perHostSettings)
        }
        .onChange(of: store.perHostSettings) { updated in
            guard !viewState.perHostState.isDirty else { return }
            viewState.perHostState.replaceItems(updated)
        }
        .onAppear {
            store.refreshAutoStartStatus()
            if !viewState.isDirty {
                viewState.markSaved(store.settings, perHostItems: store.perHostSettings)
            }
            if coordinator.settingsDestination == .perHost {
                viewState.path = [.perHost]
            }
        }
        .onChange(of: coordinator.settingsDestination) { destination in
            switch destination {
            case .perHost:
                viewState.section = .network
                DispatchQueue.main.async {
                    viewState.path = [.perHost]
                }
            case .section(let section):
                viewState.section = section
                viewState.path = []
            }
        }
        .onChange(of: viewState.section) { _ in
            guard !viewState.path.isEmpty else { return }
            viewState.path = []
            coordinator.settingsDestination = .section(viewState.section)
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
                HStack {
                    Text("界面缩放")
                    Slider(value: doubleBinding(\.uiScale, defaultValue: 1), in: 0.75...2, step: 0.05)
                    Text(String(format: "%.0f%%", (viewState.model.uiScale ?? 1) * 100))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            } header: {
                Text("外观")
            }

            Section {
                Toggle("合并标题栏和顶部工具栏", isOn: binding(\.mergeTopBarWithTitleBar))
                Toggle("显示工具栏图标标签", isOn: binding(\.showIconLabels))
                Toggle("使用相对日期时间", isOn: binding(\.useRelativeDateTime))
            } header: {
                Text("窗口")
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
            }

            Section {
                Toggle("开机启动", isOn: binding(\.autoStartOnBoot))
                LabeledContent("登录项状态") {
                    Text(store.autoStartStatusTitle)
                        .foregroundStyle(store.autoStartStatus == .enabled ? .green : .secondary)
                }
            } header: {
                Text("系统")
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
                numberStepperRow(
                    "分段线程数",
                    value: binding(\.threadCount),
                    range: 1...64
                )
                numberStepperRow(
                    "最大并发下载数（0 表示不限）",
                    value: binding(\.maxConcurrentDownloads),
                    range: 0...256
                )
                numberStepperRow(
                    "最大重试次数",
                    value: binding(\.maxDownloadRetryCount),
                    range: 0...100
                )
                numberStepperRow(
                    "全局速度限制（字节/秒，0 表示不限）",
                    value: binding(\.speedLimit),
                    range: 0...Int64.max,
                    fieldWidth: 140
                )
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
                    TextField("代理端口", value: binding(\.proxyPort), format: .number)
                        .frame(width: 100)
                    TextField("代理用户名", text: binding(\.proxyUsername))
                    SecureField("代理密码", text: binding(\.proxyPassword))
                } else if viewState.model.proxyMode == "pac" {
                    TextField("PAC 地址", text: binding(\.proxyPACURL))
                }
            } header: {
                Text("代理")
            }

            Section {
                TextField("客户端标识 User-Agent", text: binding(\.userAgent))
                Toggle("忽略 SSL 证书错误", isOn: binding(\.ignoreSSLCertificates))
            } header: {
                Text("连接")
            }

            Section("每主机设置") {
                Button("管理每主机连接和限速…", systemImage: "server.rack") {
                    coordinator.settingsDestination = .perHost
                    viewState.path = [.perHost]
                    onOpenPerHostSettings()
                }
            }
        }
    }

    private var advancedSection: some View {
        Group {
            Section {
                Toggle("跟踪磁盘上被删除的文件", isOn: binding(\.trackDeletedFilesOnDisk))
            } header: {
                Text("文件一致性")
            }

        }
    }

    private func save() {
        viewState.isSaving = true
        viewState.errorMessage = nil
        Task { @MainActor in
            let success = await store.saveSettings(viewState.model)
            if success {
                viewState.markSaved(store.settings, perHostItems: store.perHostSettings)
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

    private func doubleBinding(_ keyPath: WritableKeyPath<AppSettingsModel, Double?>, defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { viewState.model[keyPath: keyPath] ?? defaultValue },
            set: { viewState.model[keyPath: keyPath] = $0 }
        )
    }

    private func numberStepperRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        fieldWidth: CGFloat = 96
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: fieldWidth, height: 26)
                    .accessibilityLabel(Text(title))
                Stepper("", value: value, in: range, step: 1)
                    .labelsHidden()
                    .controlSize(.regular)
                    .frame(width: 28, height: 26)
                    .accessibilityLabel(Text("调整\(title)"))
            }
        }
    }

    private func numberStepperRow(
        _ title: String,
        value: Binding<Int64>,
        range: ClosedRange<Int64>,
        fieldWidth: CGFloat
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: fieldWidth, height: 26)
                    .accessibilityLabel(Text(title))
                Stepper("", value: value, in: range, step: 1)
                    .labelsHidden()
                    .controlSize(.regular)
                    .frame(width: 28, height: 26)
                    .accessibilityLabel(Text("调整\(title)"))
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch store.settings.theme.lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}

enum SettingsSection: String, CaseIterable, Hashable {
    case general
    case downloads
    case network
    case advanced

    var title: String {
        switch self {
        case .general: return "通用"
        case .downloads: return "下载"
        case .network: return "网络"
        case .advanced: return "高级"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .downloads: return "arrow.down.circle"
        case .network: return "network"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

@MainActor
final class SettingsViewState: ObservableObject {
    @Published var model: AppSettingsModel
    @Published var section: SettingsSection = .general
    @Published var path: [SettingsRoute] = []
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var isFolderPickerPresented = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    let perHostState: PerHostSettingsViewState
    private var savedModel: AppSettingsModel

    init(model: AppSettingsModel, perHostItems: [PerHostSettingsItem]) {
        self.model = model
        self.savedModel = model
        self.perHostState = PerHostSettingsViewState(items: perHostItems)
    }

    var isDirty: Bool { model != savedModel || perHostState.isDirty }

    func markSaved(_ model: AppSettingsModel, perHostItems: [PerHostSettingsItem]) {
        self.model = model
        savedModel = model
        perHostState.replaceItems(perHostItems)
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
