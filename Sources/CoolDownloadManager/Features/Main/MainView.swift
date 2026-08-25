import SwiftUI
import CoolDownloadCore

struct MainView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var coordinator: AppCoordinator

    @ObservedObject var viewState: MainViewState

    init(store: AppStore, coordinator: AppCoordinator, viewState: MainViewState) {
        self.store = store
        self.coordinator = coordinator
        self.viewState = viewState
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, coordinator: coordinator)
                .frame(minWidth: 170, idealWidth: viewState.sidebarWidth, maxWidth: 280)
        } detail: {
            VStack(spacing: 0) {
                commandBar
                Divider()
                downloadTable
                Divider()
                footer
            }
            .frame(minWidth: 700, minHeight: 480)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        coordinator.presentSettings()
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .help("打开设置")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        coordinator.presentQueues()
                    } label: {
                        Label("队列", systemImage: "list.bullet.rectangle")
                    }
                    .help("管理下载队列")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        coordinator.presentCategories()
                    } label: {
                        Label("分类", systemImage: "folder")
                    }
                    .help("管理下载分类")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $coordinator.isAddDownloadPresented) {
            AddDownloadSheet(
                urlText: $viewState.urlText,
                nameText: $viewState.nameText,
                folderURL: $viewState.folderURL,
                queueID: $viewState.queueID,
                categoryID: $viewState.categoryID,
                startImmediately: $viewState.startImmediately,
                queues: store.queues,
                categories: store.categories,
                onChooseFolder: { viewState.isShowingFolderPicker = true },
                onCancel: {
                    resetAddForm()
                    coordinator.isAddDownloadPresented = false
                },
                onAdd: { queueID, categoryID, startImmediately in
                    store.addDownload(
                        link: viewState.urlText,
                        name: viewState.nameText,
                        folder: viewState.folderURL,
                        queueID: queueID,
                        categoryID: categoryID,
                        startImmediately: startImmediately
                    )
                    resetAddForm()
                    coordinator.isAddDownloadPresented = false
                }
            )
            .onAppear {
                if !coordinator.pendingURLText.isEmpty {
                    viewState.urlText = coordinator.pendingURLText
                    coordinator.pendingURLText = ""
                }
            }
        }
        .sheet(isPresented: $coordinator.isSettingsPresented) {
            SettingsView(
                store: store,
                onClose: { coordinator.isSettingsPresented = false },
                onOpenPerHostSettings: {
                    coordinator.isSettingsPresented = false
                    coordinator.presentPerHostSettings()
                }
            )
        }
        .sheet(isPresented: $coordinator.isQueuePresented) {
            QueueView(store: store, onClose: { coordinator.isQueuePresented = false })
        }
        .sheet(isPresented: $coordinator.isBatchDownloadPresented) {
            BatchDownloadView(
                defaultFolder: URL(fileURLWithPath: store.settings.defaultDownloadFolder, isDirectory: true),
                onClose: { coordinator.isBatchDownloadPresented = false },
                onAdd: { pattern, start, end, wildcardLength, folder, startImmediately in
                    store.downloadList.addBatch(
                        pattern: pattern,
                        start: start,
                        end: end,
                        wildcardLength: wildcardLength,
                        folder: folder,
                        startImmediately: startImmediately
                    )
                }
            )
        }
        .sheet(isPresented: $coordinator.isPerHostSettingsPresented) {
            PerHostSettingsView(store: store, onClose: { coordinator.isPerHostSettingsPresented = false })
        }
        .sheet(isPresented: $coordinator.isCategoryPresented) {
            CategoryView(store: store, onClose: { coordinator.isCategoryPresented = false })
        }
        .sheet(isPresented: Binding(
            get: { coordinator.detailID != nil },
            set: { if !$0 { coordinator.closeDetail() } }
        )) {
            if let id = coordinator.detailID, let record = store.downloadList.record(id: id) {
                DownloadDetailSheet(
                    record: record,
                    store: store.downloadList,
                    coordinator: coordinator
                )
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("任务不存在")
                        .font(.headline)
                }
                .frame(width: 420, height: 240)
            }
        }
        .sheet(isPresented: Binding(
            get: { !coordinator.checksumIDs.isEmpty },
            set: { if !$0 { coordinator.closeChecksum() } }
        )) {
            let records = coordinator.checksumIDs.compactMap { store.downloadList.record(id: $0) }
            ChecksumView(
                records: records,
                service: store.service,
                onClose: { coordinator.closeChecksum() }
            )
        }
        .sheet(isPresented: Binding(
            get: {
                shouldShowCompletionDialog
            },
            set: { if !$0 { store.downloadList.acknowledgeCompletion() } }
        )) {
            if let id = store.downloadList.completedID,
               let record = store.downloadList.record(id: id) {
                CompletionView(
                    record: record,
                    store: store.downloadList,
                    coordinator: coordinator,
                    onClose: { store.downloadList.acknowledgeCompletion() }
                )
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { store.errorMessage != nil || store.downloadList.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil; store.downloadList.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? store.downloadList.errorMessage ?? "未知错误")
        }
        .alert("提示", isPresented: Binding(
            get: { coordinator.noticeMessage != nil },
            set: { if !$0 { coordinator.noticeMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(coordinator.noticeMessage ?? "")
        }
        .alert("提示", isPresented: Binding(
            get: { store.noticeMessage != nil },
            set: { if !$0 { store.noticeMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(store.noticeMessage ?? "")
        }
        .confirmationDialog(
            "删除选中的下载？",
            isPresented: $viewState.isShowingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("仅删除记录", role: .destructive) {
                store.downloadList.removeSelected()
            }
            Button("删除记录和临时文件", role: .destructive) {
                store.downloadList.removeSelected(removeFiles: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已选中 \(store.downloadList.selectedIDs.count) 个任务")
        }
        .onAppear {
            coordinator.updateMenuBar()
            if viewState.folderURL.path == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true).path {
                viewState.folderURL = URL(fileURLWithPath: store.settings.defaultDownloadFolder, isDirectory: true)
            }
        }
        .onChange(of: store.settings.useSystemTray) { _ in
            coordinator.updateMenuBar()
        }
        .onChange(of: store.downloadList.completedID) { id in
            guard let id, let record = store.downloadList.record(id: id) else { return }
            NotificationController.shared.notifyCompletion(
                record: record,
                soundEnabled: store.settings.notificationSound
            )
            if !(record.taskSettings?.showCompletionDialog ?? store.settings.showDownloadCompletionDialog) {
                store.downloadList.acknowledgeCompletion()
            } else if store.settings.focusDownloadCompletionDialogOnFinish {
                coordinator.showMainWindow()
            }
        }
        .onChange(of: store.downloadList.progressID) { id in
            guard let id else { return }
            store.downloadList.acknowledgeProgress()
            guard store.settings.showDownloadProgressDialog else { return }
            coordinator.openDetail(for: id)
            if store.settings.focusDownloadProgressDialogOnStart {
                coordinator.showMainWindow()
            }
        }
        .fileImporter(
            isPresented: $viewState.isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewState.folderURL = url
            }
        }
    }

    private var shouldShowCompletionDialog: Bool {
        guard let id = store.downloadList.completedID,
              let record = store.downloadList.record(id: id) else { return false }
        return record.taskSettings?.showCompletionDialog ?? store.settings.showDownloadCompletionDialog
    }

    private var commandBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("粘贴下载地址", text: $viewState.urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitAdd() }
                TextField("文件名（可选）", text: $viewState.nameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button {
                    submitAdd()
                } label: {
                    Label("添加并开始", systemImage: "plus.circle.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(viewState.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    coordinator.presentAddDownload()
                } label: {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis")
                }
                .help("打开完整添加下载窗口")
            }

            HStack(spacing: 8) {
                TextField("搜索名称或下载地址", text: $store.downloadList.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                Spacer()
                Menu {
                    ForEach(DownloadSort.allCases, id: \.self) { sort in
                        Button {
                            store.downloadList.sort = sort
                        } label: {
                            Label(sort.title, systemImage: store.downloadList.sort == sort ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .help("选择列表排序")
                Button {
                    store.downloadList.selectAllVisible()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("全选当前列表")
                Button {
                    store.downloadList.clearSelection()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("清除选择")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var downloadTable: some View {
        Group {
            if store.downloadList.visibleDownloads.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        tableHeader
                        ForEach(store.downloadList.visibleDownloads) { record in
                            DownloadTableRow(
                                record: record,
                                isSelected: store.downloadList.selectedIDs.contains(record.id),
                                onSelect: { store.downloadList.toggleSelection(record.id) },
                                onOpen: { open(record) },
                                onOpenDetail: { coordinator.openDetail(for: record.id) },
                                onStart: { selectAndStart(record) },
                                onPause: { selectAndPause(record) },
                                onRetry: { selectAndRetry(record) },
                                onRedownload: {
                                    store.downloadList.selectedIDs = [record.id]
                                    store.downloadList.redownloadSelected()
                                },
                                onDelete: { selectAndDelete(record) },
                                onCopyLink: { coordinator.copy(record.source.link) },
                                onChecksum: { coordinator.presentChecksum(for: [record.id]) },
                                categories: store.categories,
                                onMoveToCategory: { categoryID in
                                    store.downloadList.selectedIDs = [record.id]
                                    store.assignSelectedToCategory(categoryID, ids: [record.id])
                                }
                            )
                            Divider()
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("")
                .frame(width: 22)
            Text("名称")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("状态 / 进度")
                .frame(width: 170, alignment: .leading)
            Text("大小")
                .frame(width: 130, alignment: .trailing)
            Text("添加日期")
                .frame(width: 120, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("暂无下载")
                .font(.headline)
            Text(store.downloadList.searchText.isEmpty ? "从上方添加一个下载地址，或从剪贴板新建下载" : "没有匹配的下载任务")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("新建下载") { coordinator.presentAddDownload() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(footerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.downloadList.startSelected()
            } label: {
                Label("继续", systemImage: "play.fill")
            }
            .disabled(!store.downloadList.canStartSelection)
            Button {
                store.downloadList.pauseSelected()
            } label: {
                Label("暂停", systemImage: "pause.fill")
            }
            .disabled(!store.downloadList.canPauseSelection)
            Button {
                store.downloadList.stopAll()
            } label: {
                Label("停止全部", systemImage: "stop.fill")
            }
            .disabled(!store.downloadList.downloads.contains { $0.status == .downloading || $0.status == .preparing || $0.status == .retrying })
            Button(role: .destructive) {
                viewState.isShowingRemoveConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(!store.downloadList.hasSelection)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footerSummary: String {
        let total = store.downloadList.downloads.count
        let active = store.downloadList.downloads.filter {
            $0.status == .preparing || $0.status == .downloading || $0.status == .retrying
        }.count
        return "\(total) 个任务 · \(active) 个进行中 · 已选 \(store.downloadList.selectedIDs.count)"
    }

    private func submitAdd() {
        guard !viewState.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.addDownload(link: viewState.urlText, name: viewState.nameText, folder: viewState.folderURL)
        resetAddForm()
    }

    private func resetAddForm() {
        viewState.urlText = ""
        viewState.nameText = ""
        viewState.queueID = nil
        viewState.categoryID = nil
        viewState.startImmediately = true
    }

    private func open(_ record: DownloadRecord) {
        if record.status == .completed {
            coordinator.openFile(record)
        } else {
            coordinator.openDetail(for: record.id)
        }
    }

    private func selectAndStart(_ record: DownloadRecord) {
        store.downloadList.selectedIDs = [record.id]
        store.downloadList.startSelected()
    }

    private func selectAndPause(_ record: DownloadRecord) {
        store.downloadList.selectedIDs = [record.id]
        store.downloadList.pauseSelected()
    }

    private func selectAndRetry(_ record: DownloadRecord) {
        store.downloadList.selectedIDs = [record.id]
        store.downloadList.retrySelected()
    }

    private func selectAndDelete(_ record: DownloadRecord) {
        store.downloadList.selectedIDs = [record.id]
        viewState.isShowingRemoveConfirmation = true
    }
}

@MainActor
final class MainViewState: ObservableObject {
    @Published var urlText = ""
    @Published var nameText = ""
    @Published var folderURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
    @Published var queueID: DownloadID?
    @Published var categoryID: DownloadID?
    @Published var startImmediately = true
    @Published var isShowingFolderPicker = false
    @Published var isShowingRemoveConfirmation = false
    @Published var sidebarWidth: CGFloat = 190
}

private struct SidebarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        List(selection: Binding<DownloadFilter?>(
            get: { store.downloadList.filter },
            set: { store.downloadList.filter = $0 ?? .all }
        )) {
            Section("下载") {
                sidebarItem(.all)
                sidebarItem(.active)
                sidebarItem(.paused)
                sidebarItem(.completed)
                sidebarItem(.failed)
            }

            if !store.queues.isEmpty {
                Section("队列") {
                    ForEach(store.queues, id: \.id) { queue in
                        sidebarItem(.queue(queue.id), title: queue.name, image: "folder")
                    }
                }
            }

            if !store.categories.isEmpty {
                Section {
                    ForEach(store.categories, id: \.id) { category in
                        sidebarItem(
                            .category(category.id),
                            title: category.name,
                            image: category.icon.isEmpty ? "folder" : category.icon
                        )
                    }
                } header: {
                    HStack {
                        Text("分类")
                        Spacer()
                        Button {
                            coordinator.presentCategories()
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .buttonStyle(.plain)
                        .help("管理分类")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("下载管理器")
    }

    private func sidebarItem(_ filter: DownloadFilter, title: String? = nil, image: String? = nil) -> some View {
        Label(title ?? filter.title, systemImage: image ?? filter.systemImage)
            .tag(filter)
    }
}

private struct DownloadTableRow: View {
    let record: DownloadRecord
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onOpenDetail: () -> Void
    let onStart: () -> Void
    let onPause: () -> Void
    let onRetry: () -> Void
    let onRedownload: () -> Void
    let onDelete: () -> Void
    let onCopyLink: () -> Void
    let onChecksum: () -> Void
    let categories: [DownloadCategory]
    let onMoveToCategory: (DownloadID?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .help(isSelected ? "取消选择" : "选择任务")

            HStack(spacing: 9) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name)
                        .lineLimit(1)
                        .font(.body)
                    Text(record.source.link)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(statusText)
                    if let percent {
                        Text("\(percent)%")
                    }
                }
                if let total = record.totalBytes, total > 0 {
                    ProgressView(value: Double(record.downloadedBytes), total: Double(total))
                        .progressViewStyle(.linear)
                }
            }
            .font(.caption)
            .frame(width: 170, alignment: .leading)

            Text(sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("打开文件", systemImage: "arrow.up.right.square") { onOpen() }
                .disabled(record.status != .completed)
            Button("查看详情", systemImage: "info.circle") { onOpenDetail() }
            Divider()
            switch record.status {
            case .preparing, .downloading, .retrying:
                Button("暂停", systemImage: "pause.fill", action: onPause)
            case .failed, .cancelled:
                Button("重试", systemImage: "arrow.clockwise", action: onRetry)
            case .completed:
                Button("重新下载", systemImage: "arrow.clockwise", action: onRedownload)
            default:
                Button("继续", systemImage: "play.fill", action: onStart)
            }
            Button("复制链接", systemImage: "link", action: onCopyLink)
            if !categories.isEmpty {
                Menu("移动到分类", systemImage: "folder") {
                    Button("未分类") { onMoveToCategory(nil) }
                    Divider()
                    ForEach(categories, id: \.id) { category in
                        Button {
                            onMoveToCategory(category.id)
                        } label: {
                            Label(category.name, systemImage: category.icon.isEmpty ? "folder" : category.icon)
                        }
                    }
                }
            }
            Button("文件校验和", systemImage: "checkmark.shield", action: onChecksum)
                .disabled(record.status != .completed)
            Divider()
            Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
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

    private var percent: Int? {
        guard let total = record.totalBytes, total > 0 else { return nil }
        return Int((Double(record.downloadedBytes) / Double(total) * 100).rounded())
    }

    private var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if let total = record.totalBytes {
            return "\(formatter.string(fromByteCount: record.downloadedBytes)) / \(formatter.string(fromByteCount: total))"
        }
        return formatter.string(fromByteCount: record.downloadedBytes)
    }

    private var iconName: String {
        switch record.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .downloading, .preparing, .retrying: return "arrow.down.circle.fill"
        default: return "ellipsis.circle"
        }
    }

    private var iconColor: Color {
        switch record.status {
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        case .retrying: return .yellow
        default: return .accentColor
        }
    }
}
