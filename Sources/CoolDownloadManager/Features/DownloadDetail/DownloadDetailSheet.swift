import SwiftUI
import CoolDownloadCore

struct DownloadDetailSheet: View {
    private let initialRecord: DownloadRecord
    @ObservedObject var store: DownloadListStore
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var viewState: DownloadDetailViewState

    init(record: DownloadRecord, store: DownloadListStore, coordinator: AppCoordinator) {
        self.initialRecord = record
        self.store = store
        self.coordinator = coordinator
        _viewState = StateObject(wrappedValue: DownloadDetailViewState(record: record))
    }

    private var record: DownloadRecord {
        store.record(id: initialRecord.id) ?? initialRecord
    }

    enum DetailTab: String, CaseIterable {
        case info = "信息"
        case settings = "下载设置"
    }

    var body: some View {
        VStack(spacing: 0) {
            NativePageHeader(
                title: record.name,
                subtitle: statusText,
                systemImage: detailSystemImage,
                tint: detailTint
            ) {
                Picker("详情", selection: $viewState.tab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            Divider()

            NativePageContent {
                Group {
                    switch viewState.tab {
                    case .info:
                        infoPage
                    case .settings:
                        settingsPage
                    }
                }
            }
            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var infoPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let total = record.totalBytes, total > 0 {
                NativePageSurface {
                    HStack(alignment: .firstTextBaseline) {
                        Text("下载进度")
                            .font(.headline)
                        Spacer()
                        Text("\(percent)%")
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(record.downloadedBytes), total: Double(total))
                        .progressViewStyle(.linear)
                    Text("\(ByteCountText.string(fromByteCount: record.downloadedBytes, formatter: byteFormatter)) / \(ByteCountText.string(fromByteCount: total, formatter: byteFormatter))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            NativeSettingsGroup(title: "下载信息") {
                detailRow("状态", statusText)
                detailRow("文件大小", sizeText)
                detailRow(
                    "已下载",
                    ByteCountText.string(fromByteCount: record.downloadedBytes, formatter: byteFormatter)
                )
                detailRow("保存路径", record.destinationURL.path)
                sourceRow
                if let etag = record.etag {
                    detailRow("ETag（实体标签）", etag)
                }
                if let modified = modificationDateText {
                    detailRow("修改时间", modified, showsDivider: false)
                }
            }
            if let error = record.error {
                SettingsSectionView(title: "错误详情", description: "") {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeSettingsGroup(title: "任务下载设置") {
                NativeSettingsRow(title: "线程数") {
                    settingField(
                        placeholder: "留空使用全局设置",
                        text: $viewState.threadCount,
                        effect: threadCountEffectText
                    )
                }
                NativeSettingsRow(title: "速度限制") {
                    settingField(
                        placeholder: "字节/秒，留空使用全局设置",
                        text: $viewState.speedLimit,
                        effect: speedLimitEffectText
                    )
                }
                NativeSettingsRow(title: "完成窗口", showsDivider: false) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Picker("完成窗口", selection: $viewState.completionDialogMode) {
                            Text("使用全局设置").tag(DownloadDetailViewState.CompletionDialogMode.global)
                            Text("显示").tag(DownloadDetailViewState.CompletionDialogMode.show)
                            Text("不显示").tag(DownloadDetailViewState.CompletionDialogMode.hide)
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        effectLabel(completionDialogEffectText)
                    }
                }
            }
            if let error = viewState.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func saveTaskSettings() {
        let threadText = viewState.threadCount.trimmingCharacters(in: .whitespacesAndNewlines)
        let speedText = viewState.speedLimit.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadCount: Int?
        if threadText.isEmpty {
            threadCount = nil
        } else if let value = Int(threadText), (1...64).contains(value) {
            threadCount = value
        } else {
            viewState.errorMessage = "任务线程数必须是 1 到 64 之间的整数，或留空。"
            return
        }
        let speedLimit: Int64?
        if speedText.isEmpty {
            speedLimit = nil
        } else if let value = Int64(speedText), value >= 0 {
            speedLimit = value
        } else {
            viewState.errorMessage = "速度限制必须是非负整数，或留空。"
            return
        }
        let showCompletionDialog: Bool?
        switch viewState.completionDialogMode {
        case .global: showCompletionDialog = nil
        case .show: showCompletionDialog = true
        case .hide: showCompletionDialog = false
        }
        let settings = DownloadTaskSettings(
            threadCount: threadCount,
            speedLimit: speedLimit,
            showCompletionDialog: showCompletionDialog
        )
        viewState.isSaving = true
        viewState.errorMessage = nil
        Task { @MainActor in
            do {
                try await store.updateTaskSettings(id: record.id, settings: settings)
                viewState.isSaving = false
            } catch {
                viewState.isSaving = false
                viewState.errorMessage = error.localizedDescription
            }
        }
    }

    private var actionBar: some View {
        NativePageActionBar {
            if canShowProgress {
                Button("显示下载进度", systemImage: "chart.bar.xaxis") {
                    coordinator.showProgressPanel(for: record, focus: true)
                }
            }
            if record.status == .completed {
                Button("打开文件", systemImage: "arrow.up.right.square") {
                    coordinator.openFile(record)
                }
                Button("打开所在目录", systemImage: "folder") {
                    coordinator.revealFile(record)
                }
            }
            Spacer()
            switch record.status {
            case .preparing, .downloading, .retrying:
                Button("暂停", systemImage: "pause.fill") {
                    store.selectedIDs = [record.id]
                    store.pauseSelected()
                }
            case .failed, .cancelled:
                Button("重试", systemImage: "arrow.clockwise") {
                    store.selectedIDs = [record.id]
                    store.retrySelected()
                }
            case .completed:
                Button("重新下载", systemImage: "arrow.clockwise") {
                    store.selectedIDs = [record.id]
                    store.redownloadSelected()
                }
            default:
                Button("继续", systemImage: "play.fill") {
                    store.selectedIDs = [record.id]
                    store.startSelected()
                }
            }
            if viewState.tab == .settings {
                Button(viewState.isSaving ? "保存中…" : "保存下载设置") {
                    saveTaskSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewState.isSaving)
            }
        }
    }

    private func detailRow(_ title: String, _ value: String, showsDivider: Bool = true) -> some View {
        NativeSettingsRow(title: title, showsDivider: showsDivider) {
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 360, alignment: .trailing)
        }
    }

    private var sourceRow: some View {
        NativeSettingsRow(title: "源地址") {
            HStack(spacing: 6) {
                Text(record.source.link)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                Button {
                    coordinator.copy(record.source.link)
                    viewState.markLinkCopied()
                } label: {
                    Image(systemName: viewState.didCopyLink ? "checkmark" : "doc.on.doc")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help(viewState.didCopyLink ? "已复制" : "复制下载链接（⇧⌘C）")
                .accessibilityLabel(viewState.didCopyLink ? "下载链接已复制" : "复制下载链接")
            }
            .frame(maxWidth: 360, alignment: .trailing)
        }
    }

    private func settingField(placeholder: String, text: Binding<String>, effect: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 220)
            effectLabel(effect)
        }
    }

    private func effectLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var threadCountEffectText: String {
        if !record.parts.isEmpty || record.status == .completed {
            return "重新下载时生效"
        }
        switch record.status {
        case .added, .paused, .failed, .cancelled:
            return "下次开始时生效"
        case .preparing, .downloading, .retrying:
            return "尚未创建分片时本次生效"
        case .completed:
            return "重新下载时生效"
        }
    }

    private var speedLimitEffectText: String {
        switch record.status {
        case .preparing, .downloading, .retrying:
            return "保存后立即生效"
        case .completed:
            return "重新下载时生效"
        case .added, .paused, .failed, .cancelled:
            return "下次开始时生效"
        }
    }

    private var completionDialogEffectText: String {
        record.status == .completed ? "重新下载完成时生效" : "任务完成时生效"
    }

    private var modificationDateText: String? {
        guard let rawValue = record.lastModified else { return nil }
        guard let date = record.lastModifiedDate else { return rawValue }
        return DownloadDetailDateText.string(from: date)
    }

    private var canShowProgress: Bool {
        switch record.status {
        case .preparing, .downloading, .paused, .retrying:
            return true
        case .added, .completed, .failed, .cancelled:
            return false
        }
    }

    private var statusText: String {
        switch record.status {
        case .added: return "已添加"
        case .preparing: return "准备中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .retrying: return "重试中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private var detailSystemImage: String {
        switch record.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused, .cancelled: return "pause.circle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    private var detailTint: Color {
        switch record.status {
        case .completed: return .green
        case .failed: return .red
        case .paused, .cancelled: return .orange
        default: return .accentColor
        }
    }

    private var percent: Int {
        guard let total = record.totalBytes, total > 0 else { return 0 }
        return Int((Double(record.downloadedBytes) / Double(total) * 100).rounded())
    }

    private var sizeText: String {
        guard let total = record.totalBytes else { return "未知" }
        return ByteCountText.string(fromByteCount: total, formatter: byteFormatter)
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

}

enum DownloadDetailDateText {
    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return formatter.string(from: date)
    }
}

@MainActor
private final class DownloadDetailViewState: ObservableObject {
    @Published var tab: DownloadDetailSheet.DetailTab = .info

    enum CompletionDialogMode: String, CaseIterable {
        case global
        case show
        case hide
    }

    @Published var threadCount: String
    @Published var speedLimit: String
    @Published var completionDialogMode: CompletionDialogMode
    @Published var didCopyLink = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    private var copyFeedbackRevision = 0

    init(record: DownloadRecord) {
        let settings = record.taskSettings ?? DownloadTaskSettings()
        threadCount = settings.threadCount.map(String.init) ?? ""
        speedLimit = settings.speedLimit.map(String.init) ?? ""
        if let show = settings.showCompletionDialog {
            completionDialogMode = show ? .show : .hide
        } else {
            completionDialogMode = .global
        }
    }

    func markLinkCopied() {
        copyFeedbackRevision += 1
        let revision = copyFeedbackRevision
        didCopyLink = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.copyFeedbackRevision == revision else { return }
            self.didCopyLink = false
        }
    }
}
