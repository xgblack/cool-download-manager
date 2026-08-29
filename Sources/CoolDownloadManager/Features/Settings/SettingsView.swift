import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoolDownloadCore

enum SettingsWindowLayout {
    static let sidebarWidth: CGFloat = 224
    static let headerHeight: CGFloat = 58
    static let actionBarHeight: CGFloat = 60
}

/// The settings window inserts the sidebar as a column only while it is visible.
/// This keeps the content flush with the window edge after the sidebar is hidden.
struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var viewState: SettingsViewState
    @StateObject private var windowGuard = SettingsWindowGuard()

    init(store: AppStore, coordinator: AppCoordinator) {
        self.store = store
        self.coordinator = coordinator
        _viewState = StateObject(wrappedValue: SettingsViewState(
            model: store.settings,
            perHostItems: store.perHostSettings
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsWindowHeader(
                section: viewState.section,
                isSidebarVisible: viewState.isSidebarVisible,
                isDetailPage: !viewState.path.isEmpty,
                onToggleSidebar: toggleSidebar,
                onBack: closePerHostSettings
            )

            Divider()

            HStack(spacing: 0) {
                if viewState.path.isEmpty && viewState.isSidebarVisible {
                    settingsSidebar
                    Divider()
                }

                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewState.path.isEmpty {
                SettingsActionBar(
                    isSaving: viewState.isSaving,
                    onReset: resetToDefaults,
                    onSave: save
                )
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .preferredColorScheme(preferredColorScheme)
        .background {
            WindowAccessor { window in
                windowGuard.attach(window, isDirty: {
                    viewState.isDirty
                }, discard: {
                    viewState.markAllSaved(
                        model: store.settings,
                        perHostItems: store.perHostSettings
                    )
                })
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
        .onChange(of: store.settings) { _, updated in
            guard !viewState.isDirty, !viewState.isSaving else { return }
            viewState.markModelSaved(updated)
        }
        .onChange(of: store.perHostSettings) { _, updated in
            guard !viewState.perHostState.isDirty else { return }
            viewState.markPerHostSaved(updated)
        }
        .onAppear {
            store.refreshAutoStartStatus()
            if !viewState.isDirty {
                viewState.markAllSaved(
                    model: store.settings,
                    perHostItems: store.perHostSettings
                )
            }
            apply(coordinator.settingsDestination)
        }
        .onChange(of: coordinator.settingsDestination) { _, destination in
            apply(destination)
        }
        .onChange(of: viewState.section) { _, section in
            guard viewState.path.isEmpty else { return }
            coordinator.settingsDestination = .section(section)
        }
    }

    private var settingsSidebar: some View {
        List(selection: $viewState.section) {
            Section {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    HStack(spacing: 10) {
                        SettingsSidebarIcon(section: section)
                        Text(section.title)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .tag(section)
                    .help(section.title)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: SettingsWindowLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailContent: some View {
        if viewState.path.isEmpty {
            settingsPage
        } else {
            PerHostSettingsView(store: store, state: viewState.perHostState)
        }
    }

    @ViewBuilder
    private var settingsPage: some View {
        switch viewState.section {
        case .general:
            GeneralSettingsPage(store: store, state: viewState)
        case .downloads:
            DownloadSettingsPage(state: viewState) {
                viewState.isFolderPickerPresented = true
            }
        case .network:
            NetworkSettingsPage(state: viewState, onOpenPerHostSettings: openPerHostSettings)
        case .notifications:
            NotificationSettingsPage(state: viewState)
        case .advanced:
            AdvancedSettingsPage(state: viewState)
        }
    }

    private func toggleSidebar() {
        guard viewState.path.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            viewState.isSidebarVisible.toggle()
        }
    }

    private func openPerHostSettings() {
        coordinator.settingsDestination = .perHost
        viewState.section = .network
        viewState.path = [.perHost]
        viewState.isSidebarVisible = false
    }

    private func closePerHostSettings() {
        viewState.path = []
        viewState.section = .network
        viewState.isSidebarVisible = true
        coordinator.settingsDestination = .section(.network)
    }

    private func apply(_ destination: SettingsDestination) {
        switch destination {
        case .perHost:
            viewState.section = .network
            viewState.path = [.perHost]
            viewState.isSidebarVisible = false
        case .section(let section):
            viewState.section = section
            viewState.path = []
            viewState.isSidebarVisible = true
        }
    }

    private func resetToDefaults() {
        viewState.model = AppSettingsModel.defaults()
    }

    private func save() {
        viewState.isSaving = true
        viewState.errorMessage = nil
        Task { @MainActor in
            let success = await store.saveSettings(viewState.model)
            if success {
                viewState.markModelSaved(store.settings)
            } else {
                viewState.errorMessage = store.errorMessage ?? "设置保存失败"
            }
            viewState.isSaving = false
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch viewState.model.theme.lowercased() {
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
    case notifications
    case advanced

    var title: String {
        switch self {
        case .general: return "通用"
        case .downloads: return "下载"
        case .network: return "网络"
        case .notifications: return "通知"
        case .advanced: return "高级"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .downloads: return "arrow.down.circle"
        case .network: return "network"
        case .notifications: return "bell"
        case .advanced: return "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .secondary
        case .downloads: return .blue
        case .network: return .green
        case .notifications: return .orange
        case .advanced: return .purple
        }
    }
}

private struct SettingsWindowHeader: View {
    let section: SettingsSection
    let isSidebarVisible: Bool
    let isDetailPage: Bool
    let onToggleSidebar: () -> Void
    let onBack: () -> Void

    private var showsSidebarColumn: Bool {
        isSidebarVisible && !isDetailPage
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebarColumn {
                sidebarHeader
                Divider()
            }

            HStack(spacing: 11) {
                if isDetailPage {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help("返回网络设置")
                    .accessibilityLabel("返回网络设置")
                } else if !isSidebarVisible {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help("显示侧栏")
                    .accessibilityLabel("显示侧栏")
                }

                Image(systemName: isDetailPage ? "server.rack" : section.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isDetailPage ? .teal : section.tint)
                    .frame(width: 30, height: 30)
                    .background(
                        (isDetailPage ? Color.teal : section.tint).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                Text(isDetailPage ? "每主机设置" : section.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: SettingsWindowLayout.headerHeight)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 9) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("隐藏侧栏")
            .accessibilityLabel("隐藏侧栏")

            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("设置")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(width: SettingsWindowLayout.sidebarWidth, height: SettingsWindowLayout.headerHeight)
    }
}

@MainActor
final class SettingsViewState: ObservableObject {
    @Published var model: AppSettingsModel
    @Published var section: SettingsSection = .general
    @Published var path: [SettingsRoute] = []
    @Published var isSidebarVisible = true
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

    var isDirty: Bool {
        model != savedModel || perHostState.isDirty
    }

    func binding<Value>(_ keyPath: WritableKeyPath<AppSettingsModel, Value>) -> Binding<Value> {
        Binding(
            get: { self.model[keyPath: keyPath] },
            set: { self.model[keyPath: keyPath] = $0 }
        )
    }

    func optionalDoubleBinding(
        _ keyPath: WritableKeyPath<AppSettingsModel, Double?>,
        defaultValue: Double
    ) -> Binding<Double> {
        Binding(
            get: { self.model[keyPath: keyPath] ?? defaultValue },
            set: { self.model[keyPath: keyPath] = min(max($0, 0.75), 2) }
        )
    }

    func intBinding(
        _ keyPath: WritableKeyPath<AppSettingsModel, Int>,
        range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { self.model[keyPath: keyPath] },
            set: { self.model[keyPath: keyPath] = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    func int64Binding(
        _ keyPath: WritableKeyPath<AppSettingsModel, Int64>,
        range: ClosedRange<Int64>
    ) -> Binding<Int64> {
        Binding(
            get: { self.model[keyPath: keyPath] },
            set: { self.model[keyPath: keyPath] = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    func regenerateAPIKey() {
        model.apiAuthKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    func markModelSaved(_ model: AppSettingsModel) {
        self.model = model
        savedModel = model
    }

    func markPerHostSaved(_ items: [PerHostSettingsItem]) {
        perHostState.replaceItems(items)
    }

    func markAllSaved(model: AppSettingsModel, perHostItems: [PerHostSettingsItem]) {
        markModelSaved(model)
        markPerHostSaved(perHostItems)
    }
}

@MainActor
private final class SettingsWindowGuard: NSObject, ObservableObject, NSWindowDelegate {
    private var dirty: () -> Bool = { false }
    private var discard: () -> Void = {}

    func attach(
        _ window: NSWindow?,
        isDirty: @escaping () -> Bool,
        discard: @escaping () -> Void
    ) {
        guard let window else { return }
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
