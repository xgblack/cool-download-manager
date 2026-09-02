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
                .navigationSplitViewColumnWidth(
                    min: 210,
                    ideal: viewState.sidebarWidth,
                    max: 320
                )
        } detail: {
            NavigationStack(path: $coordinator.mainPath) {
                rootContent
                    .navigationTitle("下载")
                    .navigationDestination(for: MainDestination.self) { destination in
                        destinationView(destination)
                    }
            }
            .frame(minWidth: 760, minHeight: 520)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            workspaceToolbar
        }
        .searchable(
            text: $downloadList.searchText,
            placement: .toolbar,
            prompt: "搜索名称或地址"
        )
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
        .onChange(of: store.settings.mergeTopBarWithTitleBar) {
            coordinator.applyWindowSettings()
        }
        .onChange(of: store.settings.theme) { _, theme in
            coordinator.applyThemeToMainWindow(theme)
        }
        .onChange(of: store.downloadList.downloads) { _, downloads in
            guard case .downloadDetail(let id) = coordinator.mainPath.last,
                  !downloads.contains(where: { $0.id == id }) else { return }
            coordinator.closeDetail()
            coordinator.showNotice("下载记录已删除。")
        }
        .onChange(of: store.downloadList.failedID) { _, id in
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
        .appTheme(store.settings.theme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
    }

    private var rootContent: some View {
        Group {
            if !store.isReady {
                startupState
            } else {
                VStack(spacing: 0) {
                    downloadTable
                    footer
                }
            }
        }
    }

    @ViewBuilder
    private var startupState: some View {
        if let error = store.errorMessage {
            NativeEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "无法加载下载列表",
                message: error
            )
        } else {
            NativeEmptyState(
                systemImage: "arrow.triangle.2.circlepath",
                title: "正在加载下载列表",
                message: "正在准备下载服务。"
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: MainDestination) -> some View {
        switch destination {
        case .downloadDetail(let id):
            if let record = store.downloadList.record(id: id) {
                DownloadDetailSheet(record: record, store: store.downloadList, coordinator: coordinator)
            } else {
                ContentUnavailableFallback(title: "任务不存在", message: "该下载记录已被删除或无法读取。")
                    .navigationTitle("下载详情")
            }
        case .queues:
            QueueView(store: store)
        case .categories:
            CategoryView(store: store)
        case .appInfo(let page):
            infoView(page)
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
                    title: coordinator.activeBrowserRequest == nil ? "新建下载" : "确认下载",
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
                            startImmediately: startImmediately,
                            integrationItems: coordinator.activeBrowserRequest?.items
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
        VStack(spacing: 0) {
            NativePageHeader(
                title: page == .thirdParty ? "第三方库" : "翻译者",
                subtitle: "酷的下载管理器",
                systemImage: page == .thirdParty ? "shippingbox" : "person.2",
                tint: page == .thirdParty ? .purple : .orange
            )
            Divider()

            NativePageContent(maxWidth: NativePageLayout.compactContentWidth) {
                NativePageSurface {
                    switch page {
                    case .thirdParty:
                        Text("本应用使用 Swift 标准库、SwiftUI、AppKit、CryptoKit、UserNotifications 和 Sparkle 2.9.6；第三方许可文本随应用包提供。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .translators:
                        Text("感谢所有为项目提供翻译和反馈的贡献者。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
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

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Menu {
                ForEach(DownloadSort.allCases, id: \.self) { sort in
                    Button {
                        downloadList.sort = sort
                    } label: {
                        Label(sort.title, systemImage: downloadList.sort == sort ? "checkmark" : "arrow.up.arrow.down")
                    }
                }
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down")
            }
            .help("选择列表排序")

            Menu {
                Button("全选当前列表", systemImage: "checkmark.circle") {
                    downloadList.selectAllVisible()
                }
                Button("清除选择", systemImage: "xmark.circle") {
                    downloadList.clearSelection()
                }
                .disabled(!downloadList.hasSelection)
                Divider()
                Button("队列", systemImage: "list.bullet.rectangle") {
                    coordinator.presentQueues()
                }
                Button("分类", systemImage: "folder") {
                    coordinator.presentCategories()
                }
                Button("设置", systemImage: "gearshape") {
                    coordinator.presentSettings()
                }
            } label: {
                Label("管理", systemImage: "ellipsis.circle")
                    .modifier(IconLabelStyleModifier(showLabels: store.settings.showIconLabels))
            }
            .help("管理下载和应用设置")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                coordinator.presentBatchDownload()
            } label: {
                Label("批量下载", systemImage: "square.stack.3d.up")
                    .modifier(IconLabelStyleModifier(showLabels: store.settings.showIconLabels))
            }
            .help("批量新建下载")

            Button {
                coordinator.presentAddDownload()
            } label: {
                Label("新建下载", systemImage: "plus")
                    .modifier(IconLabelStyleModifier(showLabels: store.settings.showIconLabels))
            }
            .buttonStyle(.borderedProminent)
            .help("新建下载")
        }
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
                                onShowProgress: {
                                    coordinator.showProgressPanel(for: record, focus: true)
                                },
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
                                .padding(.leading, MainTableLayout.leadingInset)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .transaction { transaction in
                    // Progress events arrive frequently; avoid implicit
                    // layout animation making rows lag behind the source.
                    transaction.animation = nil
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.square")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: MainTableLayout.selectionWidth)
            Text("名称")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("状态 / 进度")
                .frame(width: MainTableLayout.statusWidth, alignment: .leading)
            Text("大小")
                .frame(width: MainTableLayout.sizeWidth, alignment: .trailing)
            Text("添加日期")
                .frame(width: MainTableLayout.dateWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, MainTableLayout.horizontalInset)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.downloadList.downloads.isEmpty {
            NativeEmptyState(
                systemImage: "arrow.down.circle",
                title: "暂无下载",
                message: "添加后会显示在这里。"
            )
        } else if !store.downloadList.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NativeEmptyState(
                systemImage: "magnifyingglass",
                title: "没有匹配的下载任务",
                message: "当前搜索没有匹配结果。"
            ) {
                Button("清除搜索") {
                    store.downloadList.searchText = ""
                }
            }
        } else {
            NativeEmptyState(
                systemImage: store.downloadList.filter.systemImage,
                title: "当前筛选为空",
                message: "当前筛选没有匹配结果。"
            ) {
                Button("显示全部") {
                    store.downloadList.filter = .all
                }
            }
        }
    }

    private var footer: some View {
        NativePageActionBar(usesGlass: false) {
            Label(footerSummary, systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if store.downloadList.hasSelection || hasActiveDownloads {
                Spacer(minLength: 16)
            }
            if store.downloadList.canStartSelection {
                Button {
                    store.downloadList.startSelected()
                } label: {
                    Label("继续", systemImage: "play.fill")
                }
            }
            if store.downloadList.canPauseSelection {
                Button {
                    store.downloadList.pauseSelected()
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
            }
            if hasActiveDownloads {
                Button {
                    store.downloadList.stopAll()
                } label: {
                    Label("停止全部", systemImage: "stop.fill")
                }
            }
            if store.downloadList.hasSelection {
                Button(role: .destructive) {
                    viewState.isShowingRemoveConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private var footerSummary: String {
        let total = store.downloadList.downloads.count
        let active = store.downloadList.downloads.filter {
            $0.status == .preparing || $0.status == .downloading || $0.status == .retrying
        }.count
        if store.downloadList.selectedIDs.isEmpty {
            return "\(total) 个任务 · \(active) 个进行中"
        }
        return "\(total) 个任务 · \(active) 个进行中 · 已选 \(store.downloadList.selectedIDs.count)"
    }

    private var hasActiveDownloads: Bool {
        store.downloadList.downloads.contains {
            $0.status == .downloading || $0.status == .preparing || $0.status == .retrying
        }
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

private struct DownloadDateLabel: View {
    let date: Date
    let relative: Bool

    var body: some View {
        // Refresh periodically so "刚刚" naturally becomes minutes or hours
        // even when no download event causes the row to redraw.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(displayText(at: context.date))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func displayText(at now: Date) -> String {
        guard relative else {
            return absoluteDateText
        }

        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 0 else { return "刚刚" }
        if elapsed < 60 { return "刚刚" }
        if elapsed < 60 * 60 {
            return "\(max(1, Int(elapsed / 60))) 分钟前"
        }
        if elapsed < 60 * 60 * 24 {
            return "\(max(1, Int(elapsed / (60 * 60)))) 小时前"
        }
        if elapsed < 60 * 60 * 24 * 7 {
            return "\(max(1, Int(elapsed / (60 * 60 * 24)))) 天前"
        }
        return absoluteDateText
    }

    private var absoluteDateText: String {
        date.formatted(
            .dateTime
                .locale(Locale(identifier: "zh_CN"))
                .year()
                .month()
                .day()
        )
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
    @Published var sidebarWidth: CGFloat = 240
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

private enum MainTableLayout {
    static let selectionWidth: CGFloat = 24
    static let statusWidth: CGFloat = 190
    static let sizeWidth: CGFloat = 150
    static let dateWidth: CGFloat = 132
    static let horizontalInset: CGFloat = 20
    static let leadingInset: CGFloat = horizontalInset + selectionWidth + 12
}

private struct SidebarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloadList: DownloadListStore
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 0) {
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
                            sidebarItem(.queue(queue.id), title: queue.name, image: "list.bullet.rectangle")
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
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private func sidebarItem(_ filter: DownloadFilter, title: String? = nil, image: String? = nil) -> some View {
        HStack(spacing: 9) {
            Image(systemName: image ?? filter.systemImage)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)
            Text(title ?? filter.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count(for: filter))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tag(filter)
        .help(title ?? filter.title)
    }

    private func count(for filter: DownloadFilter) -> Int {
        switch filter {
        case .all:
            return downloadList.downloads.count
        case .active:
            return downloadList.downloads.filter { isActive($0) }.count
        case .completed:
            return downloadList.downloads.filter { $0.status == .completed }.count
        case .failed:
            return downloadList.downloads.filter {
                $0.status == .failed || $0.status == .waitingForSourceRefresh
            }.count
        case .paused:
            return downloadList.downloads.filter { $0.status == .paused }.count
        case .queue(let id):
            return downloadList.downloads.filter { $0.queueID == id }.count
        case .category(let id):
            return downloadList.downloads.filter { $0.categoryID == id }.count
        }
    }

    private func isActive(_ record: DownloadRecord) -> Bool {
        record.status == .preparing || record.status == .downloading || record.status == .retrying
    }
}

private struct DownloadTableRow: View {
    let record: DownloadRecord
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onOpenDetail: () -> Void
    let onShowProgress: () -> Void
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
    @State private var isHovered = false

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
            .frame(width: MainTableLayout.selectionWidth)
            .help(isSelected ? "取消选择" : "选择任务")

            HStack(spacing: 9) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 32, height: 32)
                    .background(iconColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name)
                        .lineLimit(1)
                        .font(.body.weight(.medium))
                    Text(record.source.link)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(statusText, systemImage: statusIcon)
                        .foregroundStyle(iconColor)
                    if let percent {
                        Text("\(percent)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let total = record.totalBytes, total > 0 {
                    ProgressView(value: Double(record.downloadedBytes), total: Double(total))
                        .progressViewStyle(.linear)
                        .tint(iconColor)
                }
            }
            .font(.caption)
            .frame(width: MainTableLayout.statusWidth, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(sizeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                if let speedText {
                    Text(speedText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: MainTableLayout.sizeWidth, alignment: .trailing)

            DownloadDateLabel(date: record.createdAt, relative: relativeDate)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: MainTableLayout.dateWidth, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, MainTableLayout.horizontalInset)
        .padding(.vertical, 11)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.13)
                : isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.52) : Color.clear
        )
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("打开文件", systemImage: "arrow.up.right.square") { onOpen() }
                .disabled(record.status != .completed)
            Button("查看详情", systemImage: "info.circle") { onOpenDetail() }
            if canShowProgress {
                Button("显示下载进度", systemImage: "chart.bar.xaxis", action: onShowProgress)
            }
            Divider()
            if requiresSourceRefresh {
                Button("更新来源", systemImage: "link.badge.plus", action: onOpenDetail)
            } else {
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
            Button("验证文件完整性", systemImage: "checkmark.shield", action: onChecksum)
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
        case .waitingForSourceRefresh: return "等待更新来源"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private var percent: Int? {
        guard let total = record.totalBytes, total > 0 else { return nil }
        return Int((Double(record.downloadedBytes) / Double(total) * 100).rounded())
    }

    private var canShowProgress: Bool {
        switch record.status {
        case .preparing, .downloading, .paused, .retrying, .waitingForSourceRefresh:
            return true
        case .added, .completed, .failed, .cancelled:
            return false
        }
    }

    private var requiresSourceRefresh: Bool {
        record.status == .waitingForSourceRefresh || record.sourceRefreshReason != nil
    }

    private var statusIcon: String {
        switch record.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .waitingForSourceRefresh: return "link.badge.plus"
        case .paused: return "pause.fill"
        case .downloading, .preparing, .retrying: return "arrow.down"
        case .cancelled: return "xmark.circle.fill"
        case .added: return "clock"
        }
    }

    private var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = sizeUnit == "DecimalBytes" ? .decimal : .binary
        if let total = record.totalBytes, total > 0 {
            let downloaded = ByteCountText.string(
                fromByteCount: record.downloadedBytes,
                formatter: formatter
            )
            let totalText = ByteCountText.string(fromByteCount: total, formatter: formatter)
            return "\(downloaded) / \(totalText)"
        }
        return ByteCountText.string(fromByteCount: record.downloadedBytes, formatter: formatter)
    }

    private var speedText: String? {
        guard let speed, speed > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = speedUnit == "DecimalBytes" ? .decimal : .binary
        formatter.allowsNonnumericFormatting = false
        return "\(formatter.string(fromByteCount: Int64(speed))) / 秒"
    }

    private var iconName: String {
        switch record.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .waitingForSourceRefresh: return "link.badge.plus"
        case .paused: return "pause.circle.fill"
        case .downloading, .preparing, .retrying: return "arrow.down.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .added: return "clock.arrow.circlepath"
        }
    }

    private var iconColor: Color {
        switch record.status {
        case .completed: return .green
        case .failed: return .red
        case .waitingForSourceRefresh: return .yellow
        case .paused: return .orange
        case .retrying: return .yellow
        default: return .accentColor
        }
    }
}
