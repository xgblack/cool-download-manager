import SwiftUI
import UniformTypeIdentifiers
import CoolDownloadCore

/// Category editor matching the historical category page while keeping all
/// persistence and task assignment in AppStore/Core actors.
struct CategoryView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var state: CategoryViewState
    @Environment(\.dismiss) private var dismiss

    init(store: AppStore) {
        self.store = store
        _state = ObservedObject(wrappedValue: CategoryViewState(items: store.categories))
    }

    var body: some View {
        VStack(spacing: 0) {
            NativePageHeader(
                title: "分类",
                subtitle: "按类型整理下载任务",
                systemImage: "folder.fill",
                tint: .orange
            ) {
                Text("\(state.items.count) 个分类")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()

            HStack(spacing: 0) {
                categoryList
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                Divider()
                editor
            }
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !state.isDirty {
                state.replaceItems(store.categories)
            }
        }
        .onChange(of: store.categories) { categories in
            if !state.isDirty {
                state.replaceItems(categories)
            } else if state.pendingNew {
                state.replaceItems(categories)
                state.pendingNew = false
            }
        }
        .fileImporter(
            isPresented: $state.isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.path = url.path
                state.usePath = true
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { store.errorMessage != nil || state.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil; state.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? state.errorMessage ?? "未知错误")
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
            "放弃未保存的分类？",
            isPresented: $state.isShowingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("返回后，尚未保存的分类更改将丢失。")
        }
        .confirmationDialog(
            "切换分类并放弃更改？",
            isPresented: $state.isShowingSelectionConfirmation,
            titleVisibility: .visible
        ) {
            Button("放弃更改") {
                state.selectPendingCategory()
            }
            Button("继续编辑", role: .cancel) {
                state.pendingSelectionID = nil
            }
        } message: {
            Text("切换分类后，当前尚未保存的更改将丢失。")
        }
    }

    private func requestDismiss() {
        if state.isDirty {
            state.isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            NativeSidebarHeader(
                title: "分类",
                count: state.items.count,
                systemImage: "folder",
                tint: .orange
            )
            Divider()
            List(selection: categorySelection) {
                ForEach(state.items, id: \.id) { category in
                    HStack(spacing: 8) {
                        Image(systemName: category.icon.isEmpty ? "folder" : category.icon)
                            .foregroundStyle(category.id <= 100 ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name).lineLimit(1)
                            Text("\(category.items.count) 个项目")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(category.id))
                    .contextMenu {
                        Button("删除分类", systemImage: "trash", role: .destructive) {
                            delete(category)
                        }
                        .disabled(category.id <= 100)
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
                    state.pendingNew = true
                    store.createCategory(
                        name: "新分类",
                        path: store.settings.defaultDownloadFolder,
                        usePath: true
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建分类")
                Spacer()
                Button {
                    guard let id = state.selectedID,
                          let category = state.items.first(where: { $0.id == id }) else { return }
                    delete(category)
                } label: {
                    Image(systemName: "minus")
                }
                .help("删除分类")
                .disabled(state.selectedID == nil || (state.selectedID ?? 0) <= 100)
            }
            .buttonStyle(.borderless)
            .padding(10)
            .background(.bar)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private var categorySelection: Binding<DownloadID?> {
        Binding(
            get: { state.selectedID },
            set: { newID in
                guard newID != state.selectedID else { return }
                if state.isDirty {
                    state.pendingSelectionID = newID
                    state.isShowingSelectionConfirmation = true
                } else {
                    state.selectedID = newID
                    state.loadDraft()
                }
            }
        )
    }

    @ViewBuilder
    private var editor: some View {
        if state.selectedID != nil {
            NativePageContent(maxWidth: NativePageLayout.compactContentWidth) {
                NativeSettingsGroup(title: "基本信息") {
                    NativeSettingsRow(title: "名称") {
                        TextField("分类名称", text: $state.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 310)
                    }
                    NativeSettingsRow(title: "系统图标") {
                        HStack(spacing: 10) {
                            TextField("系统图标名称", text: $state.icon)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                            Image(systemName: state.icon.isEmpty ? "folder" : state.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                        }
                    }
                    NativeSettingsToggleRow(
                        "使用分类下载目录",
                        isOn: $state.usePath
                    )
                    NativeSettingsRow(title: "下载目录", showsDivider: false) {
                        HStack(spacing: 8) {
                            TextField("下载目录", text: $state.path)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 310)
                                .disabled(!state.usePath)
                            Button {
                                state.isFolderPickerPresented = true
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("选择分类目录")
                            .disabled(!state.usePath)
                        }
                    }
                }

                NativeSettingsGroup(title: "匹配规则") {
                    NativeSettingsRow(title: "文件扩展名") {
                        TextField("例如 dmg zip mp4", text: $state.fileTypes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 310)
                    }
                    NativeSettingsRow(title: "地址通配符", showsDivider: false) {
                        TextField("例如 *.example.com/*", text: $state.urlPatterns)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 310)
                    }
                }
            }
        } else {
            NativeEmptyState(
                systemImage: "folder",
                title: "选择一个分类",
                message: "也可以使用左下角加号新建分类"
            )
        }
    }

    private var actionBar: some View {
        NativePageActionBar {
            if let error = state.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("保存") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!state.isDirty || state.selectedID == nil)
        }
    }

    private func save() {
        guard let updated = state.commitDraft() else { return }
        store.saveCategory(updated)
        state.markSaved(updated)
    }

    private func delete(_ category: DownloadCategory) {
        guard category.id > 100 else {
            state.errorMessage = "内置分类不能删除"
            return
        }
        store.deleteCategory(id: category.id)
        state.items.removeAll { $0.id == category.id }
        state.selectedID = state.items.first?.id
        state.loadDraft()
    }
}

@MainActor
private final class CategoryViewState: ObservableObject {
    @Published var items: [DownloadCategory]
    @Published var selectedID: DownloadID?
    @Published var name = ""
    @Published var icon = "folder"
    @Published var path = ""
    @Published var usePath = true
    @Published var fileTypes = ""
    @Published var urlPatterns = ""
    @Published var isFolderPickerPresented = false
    @Published var errorMessage: String?
    @Published var pendingNew = false
    @Published var isShowingDiscardConfirmation = false
    @Published var isShowingSelectionConfirmation = false
    @Published var pendingSelectionID: DownloadID?
    private var savedDraft: DownloadCategory?

    init(items: [DownloadCategory]) {
        self.items = items
        selectedID = items.first?.id
        loadDraft()
    }

    var currentItem: DownloadCategory? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    var isDirty: Bool {
        guard let savedDraft else { return false }
        return draft != savedDraft
    }

    func replaceItems(_ values: [DownloadCategory]) {
        items = values
        if selectedID == nil || !values.contains(where: { $0.id == selectedID }) {
            selectedID = values.first?.id
        }
        loadDraft()
    }

    func loadDraft() {
        guard let currentItem else {
            name = ""
            icon = "folder"
            path = ""
            usePath = true
            fileTypes = ""
            urlPatterns = ""
            savedDraft = nil
            return
        }
        name = currentItem.name
        icon = currentItem.icon
        path = currentItem.path
        usePath = currentItem.usePath
        fileTypes = currentItem.acceptedFileTypes.joined(separator: " ")
        urlPatterns = currentItem.acceptedURLPatterns.joined(separator: " ")
        savedDraft = currentItem
    }

    func selectPendingCategory() {
        guard let pendingSelectionID else { return }
        selectedID = pendingSelectionID
        self.pendingSelectionID = nil
        isShowingSelectionConfirmation = false
        loadDraft()
    }

    func commitDraft() -> DownloadCategory? {
        guard let currentItem else { return nil }
        let updated = DownloadCategory(
            id: currentItem.id,
            name: name,
            icon: icon.isEmpty ? "folder" : icon,
            path: path,
            usePath: usePath,
            acceptedFileTypes: splitTokens(fileTypes),
            acceptedURLPatterns: splitTokens(urlPatterns),
            items: currentItem.items
        )
        guard !updated.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "分类名称不能为空"
            return nil
        }
        items = items.map { $0.id == updated.id ? updated : $0 }
        savedDraft = updated
        return updated
    }

    func markSaved(_ category: DownloadCategory) {
        savedDraft = category
    }

    private var draft: DownloadCategory? {
        guard let currentItem else { return nil }
        return DownloadCategory(
            id: currentItem.id,
            name: name,
            icon: icon.isEmpty ? "folder" : icon,
            path: path,
            usePath: usePath,
            acceptedFileTypes: splitTokens(fileTypes),
            acceptedURLPatterns: splitTokens(urlPatterns),
            items: currentItem.items
        )
    }

    private func splitTokens(_ value: String) -> [String] {
        value.split { character in
            character == "," || character == " " || character == "\n" || character == "\t"
        }.map(String.init)
    }
}
