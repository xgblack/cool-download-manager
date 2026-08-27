import SwiftUI
import CoolDownloadCore

struct QueueView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var state: QueueViewState
    @Environment(\.dismiss) private var dismiss

    init(store: AppStore) {
        self.store = store
        _state = ObservedObject(wrappedValue: QueueViewState())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                queueList
                    .frame(minWidth: 210, idealWidth: 230, maxWidth: 260)
                Divider()
                queueDetails
            }
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !state.isEditing {
                state.selectFirstIfNeeded(store.queueModels)
                state.refreshDraft(from: selectedModel)
            }
        }
        .onChange(of: store.queueModels) { models in
            state.selectFirstIfNeeded(models)
            if !state.isEditing {
                state.refreshDraft(from: selectedModel)
            }
        }
        .onChange(of: state.selectedQueueID) { _ in
            state.refreshDraft(from: selectedModel)
        }
        .alert("操作失败", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "未知错误")
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    requestDismiss()
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .help("返回下载列表")
            }
        }
        .confirmationDialog(
            "放弃未保存的队列？",
            isPresented: $state.isShowingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("返回后，尚未保存的队列更改将丢失。")
        }
        .confirmationDialog(
            "切换队列并放弃更改？",
            isPresented: $state.isShowingSelectionConfirmation,
            titleVisibility: .visible
        ) {
            Button("放弃更改") { state.selectPendingQueue(from: store.queueModels) }
            Button("继续编辑", role: .cancel) { state.pendingQueueID = nil }
        } message: {
            Text("切换队列后，当前尚未保存的更改将丢失。")
        }
    }

    private func requestDismiss() {
        if state.isEditing || state.isCreatingQueue {
            state.isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private var selectedModel: DownloadQueueModel? {
        guard let id = state.selectedQueueID else { return nil }
        return store.queueModels.first { $0.id == id }
    }

    private var queueSelection: Binding<DownloadID?> {
        Binding(
            get: { state.selectedQueueID },
            set: { newID in
                guard newID != state.selectedQueueID else { return }
                if state.isEditing {
                    state.pendingQueueID = newID
                    state.isShowingSelectionConfirmation = true
                } else {
                    state.selectedQueueID = newID
                    state.refreshDraft(from: store.queueModels.first { $0.id == newID })
                }
            }
        )
    }

    private var queueList: some View {
        VStack(spacing: 0) {
            NativeSidebarHeader(
                title: "队列",
                count: store.queueModels.count,
                systemImage: "list.bullet.rectangle",
                tint: .blue
            )
            Divider()
            List(selection: queueSelection) {
                ForEach(store.queueModels) { queue in
                    HStack(spacing: 8) {
                        Image(systemName: queue.id == 0 ? "tray.full" : "folder")
                            .foregroundStyle(queue.id == 0 ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(queue.name).lineLimit(1)
                            Text("\(queue.queueItems.count) 个项目")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(queue.id))
                    .contextMenu {
                        if queue.id != 0 {
                            Button("删除队列", systemImage: "trash", role: .destructive) {
                                store.deleteQueue(id: queue.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            Divider()
            HStack {
                Button {
                    state.newQueueName = ""
                    state.isCreatingQueue = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建队列")
                Spacer()
                Button {
                    guard let id = state.selectedQueueID, id != 0 else { return }
                    store.deleteQueue(id: id)
                } label: {
                    Image(systemName: "minus")
                }
                .help("删除队列")
                .disabled(state.selectedQueueID == nil || state.selectedQueueID == 0)
            }
            .buttonStyle(.borderless)
            .padding(10)
            .background(.bar)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    @ViewBuilder
    private var queueDetails: some View {
        if state.isCreatingQueue {
            newQueueEditor
        } else if let model = selectedModel {
            NativePageContent {
                NativeSettingsGroup(title: "队列设置") {
                    NativeSettingsRow(title: "队列名称") {
                        TextField("队列名称", text: $state.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .disabled(model.id == 0)
                    }
                    NativeSettingsNumberRow(
                        "最大并发",
                        value: Binding(
                            get: { state.maxConcurrentValue },
                            set: { state.setMaxConcurrentValue($0) }
                        ),
                        range: 1...32
                    )
                    NativeSettingsToggleRow("队列为空时自动停止", isOn: $state.stopQueueOnEmpty)
                    NativeSettingsRow(title: "完成后动作", showsDivider: false) {
                        Picker("完成后动作", selection: $state.completionAction) {
                            Text("不执行动作").tag(QueueCompletionAction.none)
                            Text("关机").tag(QueueCompletionAction.shutdown)
                            Text("睡眠").tag(QueueCompletionAction.sleep)
                            Text("休眠").tag(QueueCompletionAction.hibernate)
                            Text("锁定屏幕").tag(QueueCompletionAction.lock)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                }

                NativeSettingsGroup(title: "调度") {
                    NativeSettingsToggleRow(
                        "启用调度",
                        isOn: Binding(
                            get: { state.schedulerEnabled },
                            set: { state.setSchedulerEnabled($0) }
                        ),
                        showsDivider: state.schedulerEnabled
                    )
                    if state.schedulerEnabled {
                        NativeSettingsToggleRow("自动开始", isOn: $state.enabledStartTime)
                        NativeSettingsRow(title: "开始时间") {
                            TextField("HH:mm", text: $state.startTime)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .disabled(!state.enabledStartTime)
                        }
                        NativeSettingsToggleRow("自动停止", isOn: $state.enabledEndTime)
                        NativeSettingsRow(title: "停止时间") {
                            TextField("HH:mm", text: $state.endTime)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .disabled(!state.enabledEndTime)
                        }
                        NativeSettingsRow(title: "活动日", showsDivider: false) {
                            dayPicker
                        }
                    }
                }
                queueItemsSection(model)
            }
        } else {
            ContentUnavailableFallback(title: "没有队列", message: "新建一个队列开始管理任务。")
        }
    }

    private var newQueueEditor: some View {
        NativePageContent(maxWidth: NativePageLayout.compactContentWidth) {
            NativeSettingsGroup(title: "新建队列") {
                NativeSettingsRow(title: "队列名称", showsDivider: false) {
                    TextField("队列名称", text: $state.newQueueName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit { createQueue() }
                }
            }
        }
    }

    private var actionBar: some View {
        NativePageActionBar {
            if state.isCreatingQueue {
                Spacer()
                Button("取消") {
                    state.isCreatingQueue = false
                }
                .keyboardShortcut(.cancelAction)
                Button("添加") {
                    createQueue()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.newQueueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let model = selectedModel, state.isEditing {
                    Button("恢复") { state.refreshDraft(from: model) }
                    Button("保存") { save(model) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                Button {
                    guard let id = state.selectedQueueID else { return }
                    store.stopQueue(id)
                } label: {
                    Label("停止队列", systemImage: "stop.fill")
                }
                .disabled(state.selectedQueueID == nil)
                Button {
                    guard let id = state.selectedQueueID else { return }
                    store.startQueue(id)
                } label: {
                    Label("启动队列", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.selectedQueueID == nil)
            }
        }
    }

    private func createQueue() {
        let name = state.newQueueName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.createQueue(name: name)
        state.isCreatingQueue = false
    }

    private var dayPicker: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                let selected = state.daysOfWeek.contains(day)
                Button(dayNames[day - 1]) {
                    if selected {
                        state.daysOfWeek.remove(day)
                    } else {
                        state.daysOfWeek.insert(day)
                    }
                }
                .buttonStyle(.bordered)
                .tint(selected ? .accentColor : .secondary)
                .help(dayNames[day - 1])
            }
        }
    }

    private func queueItemsSection(_ model: DownloadQueueModel) -> some View {
        let records = model.queueItems.compactMap { store.downloadList.record(id: $0) }
        return SettingsSectionView(title: "下载任务", description: "") {
            if records.isEmpty {
                Text("队列中没有下载任务")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Image(systemName: record.status == .completed ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(record.status == .completed ? .green : .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name).lineLimit(1)
                            Text(record.source.link).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { moveItem(record.id, offset: -1, in: model) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button { moveItem(record.id, offset: 1, in: model) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == records.count - 1)
                        Button { store.removeSelectedFromQueue(model.id, ids: [record.id]) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("移出队列")
                    }
                    .padding(.vertical, 3)
                }
            }
            HStack {
                Button("将选中任务加入队列", systemImage: "plus") {
                    store.addSelectedToQueue(model.id, ids: store.downloadList.selectedIDs)
                }
                .disabled(store.downloadList.selectedIDs.isEmpty)
                Spacer()
                Button("清空项目", systemImage: "trash") {
                    store.removeSelectedFromQueue(model.id, ids: Set(model.queueItems))
                }
                .disabled(model.queueItems.isEmpty)
            }
        }
    }

    private func save(_ model: DownloadQueueModel) {
        var updated = model
        updated.name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.maxConcurrent = state.maxConcurrentValue
        updated.stopQueueOnEmpty = state.stopQueueOnEmpty
        updated.completionAction = state.completionAction
        updated.scheduledTimes = QueueSchedule(
            daysOfWeek: state.daysOfWeek,
            startTime: state.startTime,
            endTime: state.endTime,
            enabledStartTime: state.schedulerEnabled && state.enabledStartTime,
            enabledEndTime: state.schedulerEnabled && state.enabledEndTime
        )
        store.saveQueue(updated)
        state.markSaved(updated)
    }

    private func moveItem(_ id: DownloadID, offset: Int, in model: DownloadQueueModel) {
        guard let index = model.queueItems.firstIndex(of: id) else { return }
        let target = index + offset
        guard model.queueItems.indices.contains(target) else { return }
        var items = model.queueItems
        items.swapAt(index, target)
        guard let queueStore = store.queueModels.first(where: { $0.id == model.id }) else { return }
        var updated = queueStore
        updated.queueItems = items
        store.saveQueue(updated)
    }

    private var summary: String {
        let count = selectedModel?.queueItems.count ?? 0
        return "队列项目：\(count)"
    }

    private let dayNames = ["一", "二", "三", "四", "五", "六", "日"]
}

@MainActor
private final class QueueViewState: ObservableObject {
    @Published var selectedQueueID: DownloadID?
    @Published var isCreatingQueue = false
    @Published var newQueueName = ""
    @Published var isShowingDiscardConfirmation = false
    @Published var isShowingSelectionConfirmation = false
    @Published var pendingQueueID: DownloadID?
    @Published var name = ""
    @Published var maxConcurrent = "2"
    @Published var maxConcurrentValue = 2
    @Published var stopQueueOnEmpty = false
    @Published var completionAction: QueueCompletionAction = .none
    @Published var schedulerEnabled = false
    @Published var enabledStartTime = false
    @Published var enabledEndTime = false
    @Published var startTime = "02:30"
    @Published var endTime = "07:30"
    @Published var daysOfWeek = Set(1...7)

    private var savedModel: DownloadQueueModel?

    var isEditing: Bool { savedModel != nil && isDirty }

    func selectFirstIfNeeded(_ models: [DownloadQueueModel]) {
        guard let first = models.first else {
            selectedQueueID = nil
            return
        }
        if selectedQueueID == nil || !models.contains(where: { $0.id == selectedQueueID }) {
            selectedQueueID = first.id
        }
    }

    func refreshDraft(from model: DownloadQueueModel?) {
        guard let model else { return }
        savedModel = model
        name = model.name
        maxConcurrentValue = model.maxConcurrent
        maxConcurrent = String(model.maxConcurrent)
        stopQueueOnEmpty = model.stopQueueOnEmpty
        completionAction = model.completionAction
        enabledStartTime = model.scheduledTimes.enabledStartTime
        enabledEndTime = model.scheduledTimes.enabledEndTime
        schedulerEnabled = enabledStartTime || enabledEndTime
        startTime = model.scheduledTimes.startTime
        endTime = model.scheduledTimes.endTime
        daysOfWeek = model.scheduledTimes.daysOfWeek
    }

    func markSaved(_ model: DownloadQueueModel) {
        savedModel = model
        refreshDraft(from: model)
    }

    func setMaxConcurrentText(_ value: String) {
        maxConcurrent = value
        guard let parsed = Int(value) else { return }
        maxConcurrentValue = min(max(parsed, 1), 32)
    }

    func setMaxConcurrentValue(_ value: Int) {
        maxConcurrentValue = min(max(value, 1), 32)
        maxConcurrent = String(maxConcurrentValue)
    }

    func setSchedulerEnabled(_ enabled: Bool) {
        schedulerEnabled = enabled
        if !enabled {
            enabledStartTime = false
            enabledEndTime = false
        }
    }

    func selectPendingQueue(from models: [DownloadQueueModel]) {
        guard let pendingQueueID else { return }
        selectedQueueID = pendingQueueID
        self.pendingQueueID = nil
        isShowingSelectionConfirmation = false
        refreshDraft(from: models.first { $0.id == pendingQueueID })
    }

    var isDirty: Bool {
        guard let savedModel else { return false }
        let draftSchedule = QueueSchedule(
            daysOfWeek: daysOfWeek,
            startTime: startTime,
            endTime: endTime,
            enabledStartTime: schedulerEnabled && enabledStartTime,
            enabledEndTime: schedulerEnabled && enabledEndTime
        )
        return savedModel.name != name.trimmingCharacters(in: .whitespacesAndNewlines)
            || savedModel.maxConcurrent != maxConcurrentValue
            || savedModel.stopQueueOnEmpty != stopQueueOnEmpty
            || savedModel.completionAction != completionAction
            || savedModel.scheduledTimes != draftSchedule
    }
}

struct ContentUnavailableFallback: View {
    let title: String
    let message: String

    var body: some View {
        NativeEmptyState(
            systemImage: "list.bullet.rectangle",
            title: title,
            message: message
        )
    }
}
