import SwiftUI
import CoolDownloadCore

struct MainView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloadList: DownloadListStore
    @ObservedObject var coordinator: AppCoordinator

    @ObservedObject var viewState: MainViewState

    init(store: AppStore, coordinator: AppCoordinator, viewState: MainViewState) {
        self.store = store
        self._downloadList = ObservedObject(wrappedValue: store.downloadList)
        self.coordinator = coordinator
        self.viewState = viewState
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, downloadList: downloadList, coordinator: coordinator)
                .frame(minWidth: 170, idealWidth: viewState.sidebarWidth, maxWidth: 280)
        } detail: {
            NavigationStack(path: $coordinator.mainPath) {
                rootContent
                    .navigationDestination(for: MainDestination.self) { destination in
                        destinationView(destination)
                    }
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button {
                                coordinator.presentSettings()
                            } label: {
                                Label("设置", systemImage: "gearshape")
                                    .modifier(IconLabelStyleModifier(showLabels: store.settings.showIconLabels))
                            }
                            .help("打开设置")
                        }
                        ToolbarItem(placement: .automatic) {
                            Button {
                                coordinator.presentQueues()
                            } label: {
                                Label("队列", systemImage: "list.bullet.rectangle")
                                    .modifier(IconLabelStyleModifier(showLabels: store.settings.showIconLabels))
                            }
                            .help("管理下载队列")
                        }
                        ToolbarItem(placement: .automatic) {
                            Button {
                                coordinator.presentCategories()
                            } label: {
                                Label("分类", systemImage: "folder")
                                    .modifier(IconLabelStyleModifier(showLabels: store.settings.showIconLabels))
                            }
                            .help("管理下载分类")
                        }
                    }
            }
            .frame(minWidth: 700, minHeight: 480)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $coordinator.mainSheet) { sheet in
            sheetView(sheet)
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
        .onChange(of: store.settings.mergeTopBarWithTitleBar) { _ in
            coordinator.applyWindowSettings()
        }
        .onChange(of: store.downloadList.completedID) { id in
            guard let id, let record = store.downloadList.record(id: id) else { return }
            if !(record.taskSettings?.showCompletionDialog ?? store.settings.showDownloadCompletionDialog) {
                store.downloadList.acknowledgeCompletion()
            } else {
                coordinator.showCompletionPanel(
                    for: record,
                    focus: store.settings.focusDownloadCompletionDialogOnFinish
                )
            }
        }
        .onChange(of: store.downloadList.progressID) { id in
            guard let id else { return }
            store.downloadList.acknowledgeProgress()
            guard store.settings.showDownloadProgressDialog else { return }
            guard let record = store.downloadList.record(id: id) else { return }
            coordinator.showProgressPanel(
                for: record,
                focus: store.settings.focusDownloadProgressDialogOnStart
            )
        }
        .onChange(of: store.downloadList.downloads) { downloads in
            guard case .downloadDetail(let id) = coordinator.mainPath.last,
                  !downloads.contains(where: { $0.id == id }) else { return }
            coordinator.closeDetail()
            coordinator.showNotice("下载记录已删除。")
        }
        .onChange(of: store.downloadList.failedID) { id in
            guard id != nil else { return }
            store.downloadList.acknowledgeFailure()
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
        .preferredColorScheme(preferredColorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            commandBar
            Divider()
            downloadTable
            Divider()
            footer
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: MainDestination) -> some View {
        switch destination {
        case .downloadDetail(let id):
            if let record = store.downloadList.record(id: id) {
                DownloadDetailSheet(record: record, store: store.downloadList, coordinator: coordinator)
                    .navigationTitle(record.name)
            } else {
                ContentUnavailableFallback(title: "任务不存在", message: "该下载记录已被删除或无法读取。")
                    .navigationTitle("下载详情")
            }
        case .queues:
            QueueView(store: store)
                .navigationTitle("队列")
        case .categories:
            CategoryView(store: store)
                .navigationTitle("分类")
        case .appInfo(let page):
            infoView(page)
                .navigationTitle(page == .thirdParty ? "第三方库" : "翻译者")
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: MainSheet) -> some View {
        switch sheet {
        case .addDownload:
            NavigationStack {
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
                        coordinator.closeMainSheet()
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
                        coordinator.closeMainSheet()
                    }
                )
                .onAppear {
                    if !coordinator.pendingURLText.isEmpty {
                        viewState.urlText = coordinator.pendingURLText
                        coordinator.pendingURLText = ""
                    }
                }
                .onDisappear {
                    if coordinator.mainSheet == nil {
                        resetAddForm()
                    }
                }
            }
        case .batchDownload:
            NavigationStack {
                BatchDownloadView(
                    defaultFolder: URL(fileURLWithPath: store.settings.defaultDownloadFolder, isDirectory: true),
                    onClose: coordinator.closeMainSheet,
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
        case .checksum(let ids):
            NavigationStack {
                let records = ids.compactMap { store.downloadList.record(id: $0) }
                ChecksumView(records: records, service: store.service, onClose: coordinator.closeMainSheet)
            }
        }
    }

    @ViewBuilder
    private func infoView(_ page: MainInfoPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch page {
                case .thirdParty:
                    Text("第三方库").font(.title2.weight(.semibold))
                    Text("本应用使用 Swift 标准库、SwiftUI、AppKit、CryptoKit 和 UserNotifications。")
                        .foregroundStyle(.secondary)
                case .translators:
                    Text("翻译者").font(.title2.weight(.semibold))
                    Text("感谢所有为项目提供翻译和反馈的贡献者。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch store.settings.theme.lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private var dynamicTypeSize: DynamicTypeSize {
        switch store.settings.uiScale ?? 1 {
        case ..<0.85: return .xSmall
        case ..<0.95: return .small
        case ..<1.05: return .medium
        case ..<1.2: return .large
        case ..<1.4: return .xLarge
        default: return .xxLarge
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
                                speed: store.downloadList.speed(
                                    for: record.id,
                                    average: store.settings.useAverageSpeed
                                ),
                                relativeDate: store.settings.useRelativeDateTime,
                                sizeUnit: store.settings.sizeUnit,
                                speedUnit: store.settings.speedUnit,
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

private struct IconLabelStyleModifier: ViewModifier {
    let showLabels: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if showLabels {
            content.labelStyle(.titleAndIcon)
        } else {
            content.labelStyle(.iconOnly)
        }
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
    @ObservedObject var downloadList: DownloadListStore
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        List(selection: Binding<DownloadFilter?>(
            get: { downloadList.filter },
            set: { downloadList.filter = $0 ?? .all }
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
            .tag(Optional(filter))
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
    let speed: Double?
    let relativeDate: Bool
    let sizeUnit: String
    let speedUnit: String
    let onMoveToCategory: (DownloadID?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isSelected },
                    set: { newValue in
                        guard newValue != isSelected else { return }
                        onSelect()
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
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

            VStack(alignment: .trailing, spacing: 2) {
                Text(sizeText)
                if let speedText {
                    Text(speedText)
                        .foregroundStyle(.secondary)
                }
            }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            Group {
                if relativeDate {
                    Text(record.createdAt, style: .relative)
                } else {
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
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
        formatter.countStyle = sizeUnit == "DecimalBytes" ? .decimal : .binary
        if let total = record.totalBytes {
            return "\(formatter.string(fromByteCount: record.downloadedBytes)) / \(formatter.string(fromByteCount: total))"
        }
        return formatter.string(fromByteCount: record.downloadedBytes)
    }

    private var speedText: String? {
        guard let speed, speed > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = speedUnit == "DecimalBytes" ? .decimal : .binary
        return "\(formatter.string(fromByteCount: Int64(speed))) / 秒"
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
