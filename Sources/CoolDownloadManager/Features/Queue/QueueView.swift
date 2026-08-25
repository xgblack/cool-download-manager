import SwiftUI
import CoolDownloadCore

struct QueueView: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @ObservedObject private var state: QueueViewState

    init(store: AppStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        _state = ObservedObject(wrappedValue: QueueViewState())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("队列", systemImage: "list.bullet.rectangle")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(16)
            Divider()

            HStack(spacing: 0) {
                queueList
                    .frame(width: 210)
                Divider()
                queueDetails
            }
            Divider()
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let id = state.selectedQueueID else { return }
                    store.stopQueue(id)
                } label: {
                    Label("停止队列", systemImage: "stop.fill")
                }
                Button {
                    guard let id = state.selectedQueueID else { return }
                    store.startQueue(id)
                } label: {
                    Label("启动队列", systemImage: "play.fill")
                }
                .disabled(state.selectedQueueID == nil)
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 820, height: 590)
        .onAppear {
            state.selectFirstIfNeeded(store.queueModels)
            state.refreshDraft(from: selectedModel)
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
        .sheet(isPresented: $state.isCreatingQueue) {
            NewQueueSheet(
                onCancel: { state.isCreatingQueue = false },
                onCreate: { name in
                    store.createQueue(name: name)
                    state.isCreatingQueue = false
                }
            )
        }
    }

    private var selectedModel: DownloadQueueModel? {
        guard let id = state.selectedQueueID else { return nil }
        return store.queueModels.first { $0.id == id }
    }

    private var queueList: some View {
        VStack(spacing: 0) {
            List(selection: $state.selectedQueueID) {
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
            Divider()
            HStack {
                Button {
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
        }
    }

    @ViewBuilder
    private var queueDetails: some View {
        if let model = selectedModel {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSectionView(title: model.name, description: model.id == 0 ? "主队列" : "队列配置和项目顺序") {
                        TextField("队列名称", text: $state.name)
                            .disabled(model.id == 0)
                        HStack {
                            Text("最大并发")
                            TextField("1-32", text: Binding(
                                get: { state.maxConcurrent },
                                set: { state.setMaxConcurrentText($0) }
                            ))
                                .frame(width: 70)
                            Stepper("", value: Binding(
                                get: { state.maxConcurrentValue },
                                set: { state.setMaxConcurrentValue($0) }
                            ), in: 1...32)
                                .labelsHidden()
                        }
                        Toggle("队列为空时自动停止", isOn: $state.stopQueueOnEmpty)
                        Picker("完成后动作", selection: $state.completionAction) {
                            Text("不执行动作").tag(QueueCompletionAction.none)
                            Text("关机").tag(QueueCompletionAction.shutdown)
                            Text("睡眠").tag(QueueCompletionAction.sleep)
                            Text("休眠").tag(QueueCompletionAction.hibernate)
                            Text("锁定屏幕").tag(QueueCompletionAction.lock)
                        }

                        Divider()
                        Toggle("启用调度", isOn: Binding(
                            get: { state.schedulerEnabled },
                            set: { state.setSchedulerEnabled($0) }
                        ))
                        if state.schedulerEnabled {
                            Toggle("自动开始", isOn: $state.enabledStartTime)
                            TextField("开始时间（HH:mm）", text: $state.startTime)
                                .disabled(!state.enabledStartTime)
                            Toggle("自动停止", isOn: $state.enabledEndTime)
                            TextField("停止时间（HH:mm）", text: $state.endTime)
                                .disabled(!state.enabledEndTime)
                            dayPicker
                        }
                        HStack {
                            Spacer()
                            Button("恢复") { state.refreshDraft(from: model) }
                            Button("保存") { save(model) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!state.isDirty)
                        }
                    }

                    queueItemsSection(model)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableFallback(title: "没有队列", message: "新建一个队列开始管理任务。")
        }
    }

    private var dayPicker: some View {
        HStack(spacing: 6) {
            Text("活动日")
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
        return SettingsSectionView(title: "项目", description: "按顺序运行队列中的下载任务。") {
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

private struct NewQueueSheet: View {
    let onCancel: () -> Void
    let onCreate: (String) -> Void
    @ObservedObject private var state: NewQueueState

    init(onCancel: @escaping () -> Void, onCreate: @escaping (String) -> Void) {
        self.onCancel = onCancel
        self.onCreate = onCreate
        _state = ObservedObject(wrappedValue: NewQueueState())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建队列").font(.title3.weight(.semibold))
            TextField("队列名称", text: $state.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("添加", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    private func create() {
        let value = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onCreate(value)
    }
}

@MainActor
private final class NewQueueState: ObservableObject {
    @Published var name = ""
}

private struct ContentUnavailableFallback: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
