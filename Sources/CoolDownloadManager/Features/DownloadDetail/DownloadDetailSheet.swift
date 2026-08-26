import SwiftUI
import CoolDownloadCore

struct DownloadDetailSheet: View {
    private let initialRecord: DownloadRecord
    @ObservedObject var store: DownloadListStore
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var viewState: DownloadDetailViewState

    init(record: DownloadRecord, store: DownloadListStore, coordinator: AppCoordinator) {
        self.initialRecord = record
        self.store = store
        self.coordinator = coordinator
        _viewState = ObservedObject(wrappedValue: DownloadDetailViewState(record: record))
    }

    private var record: DownloadRecord {
        store.record(id: initialRecord.id) ?? initialRecord
    }

    enum DetailTab: String, CaseIterable {
        case info = "信息"
        case settings = "速度与设置"
        case completion = "完成后动作"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("详情", selection: $viewState.tab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                Group {
                    switch viewState.tab {
                    case .info:
                        infoPage
                    case .settings:
                        settingsPage
                    case .completion:
                        completionPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var infoPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let total = record.totalBytes, total > 0 {
                ProgressView(value: Double(record.downloadedBytes), total: Double(total))
                    .progressViewStyle(.linear)
                HStack {
                    Text("进度")
                    Spacer()
                    Text("\(percent)%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            detailRow("状态", statusText)
            detailRow("文件大小", sizeText)
            detailRow(
                "已下载",
                ByteCountText.string(fromByteCount: record.downloadedBytes, formatter: byteFormatter)
            )
            detailRow("保存路径", record.destinationURL.path)
            detailRow("源地址", record.source.link)
            if let etag = record.etag {
            detailRow("ETag（实体标签）", etag)
            }
            if let modified = record.lastModified {
            detailRow("Last-Modified（修改时间）", modified)
            }
            if let error = record.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text("错误详情")
                        .font(.subheadline.weight(.semibold))
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("任务级下载设置")
                .font(.headline)
            Text("留空的数值会继承全局设置；保存后下次开始或重试任务时生效。")
                .foregroundStyle(.secondary)
            LabeledContent("线程数") {
                TextField("留空使用全局", text: $viewState.threadCount)
                    .frame(width: 150)
            }
            LabeledContent("速度限制") {
                TextField("字节/秒，留空使用全局", text: $viewState.speedLimit)
                    .frame(width: 190)
            }
            Toggle("显示分段信息", isOn: $viewState.showPartInfo)
            if let error = viewState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(viewState.isSaving ? "保存中…" : "保存下载设置") {
                    saveTaskSettings()
                }
                .disabled(viewState.isSaving)
            }
        }
    }

    private var completionPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("完成后动作")
                .font(.headline)
            Picker("电源动作", selection: $viewState.completionAction) {
                Text("不执行动作").tag(QueueCompletionAction.none)
                Text("关机").tag(QueueCompletionAction.shutdown)
                Text("睡眠").tag(QueueCompletionAction.sleep)
                Text("休眠").tag(QueueCompletionAction.hibernate)
                Text("锁定屏幕").tag(QueueCompletionAction.lock)
            }
            Picker("完成窗口", selection: $viewState.completionDialogMode) {
                Text("使用全局设置").tag(DownloadDetailViewState.CompletionDialogMode.global)
                Text("显示").tag(DownloadDetailViewState.CompletionDialogMode.show)
                Text("不显示").tag(DownloadDetailViewState.CompletionDialogMode.hide)
            }
            if let error = viewState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(viewState.isSaving ? "保存中…" : "保存完成设置") {
                    saveTaskSettings()
                }
                .disabled(viewState.isSaving)
            }
            Text("电源动作会在完成事件中记录；执行前需要 macOS 权限和用户确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            completionAction: viewState.completionAction,
            showCompletionDialog: showCompletionDialog,
            showPartInfo: viewState.showPartInfo
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
        HStack {
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
        }
        .padding(12)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
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

    private var iconName: String {
        switch record.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        default: return "arrow.down.circle.fill"
        }
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
    @Published var completionAction: QueueCompletionAction
    @Published var completionDialogMode: CompletionDialogMode
    @Published var showPartInfo: Bool
    @Published var isSaving = false
    @Published var errorMessage: String?

    init(record: DownloadRecord) {
        let settings = record.taskSettings ?? DownloadTaskSettings()
        threadCount = settings.threadCount.map(String.init) ?? ""
        speedLimit = settings.speedLimit.map(String.init) ?? ""
        completionAction = settings.completionAction
        if let show = settings.showCompletionDialog {
            completionDialogMode = show ? .show : .hide
        } else {
            completionDialogMode = .global
        }
        showPartInfo = settings.showPartInfo
    }
}
