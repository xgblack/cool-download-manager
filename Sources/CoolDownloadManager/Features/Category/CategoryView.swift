import SwiftUI
import UniformTypeIdentifiers
import CoolDownloadCore

/// Category editor matching the historical category page while keeping all
/// persistence and task assignment in AppStore/Core actors.
struct CategoryView: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @ObservedObject private var state: CategoryViewState

    init(store: AppStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        _state = ObservedObject(wrappedValue: CategoryViewState(items: store.categories))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("分类", systemImage: "folder")
                    .font(.title3.weight(.semibold))
                Spacer()
                if state.isDirty {
                    Text("未保存")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(16)
            Divider()

            HStack(spacing: 0) {
                categoryList
                    .frame(width: 220)
                Divider()
                editor
            }
            Divider()
            HStack {
                if let error = state.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!state.isDirty || state.selectedID == nil)
            }
            .padding(12)
        }
        .frame(width: 820, height: 600)
        .onAppear {
            state.replaceItems(store.categories)
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
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            List(selection: $state.selectedID) {
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
        }
    }

    @ViewBuilder
    private var editor: some View {
        if state.selectedID != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSectionView(title: "分类配置", description: "分类可按文件扩展名和 URL 通配符自动匹配。") {
                        TextField("名称", text: $state.name)
                        HStack {
                            TextField("SF Symbol 图标", text: $state.icon)
                            Image(systemName: state.icon.isEmpty ? "folder" : state.icon)
                                .frame(width: 24)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("使用分类下载目录", isOn: $state.usePath)
                        HStack {
                            TextField("下载目录", text: $state.path)
                                .disabled(!state.usePath)
                            Button {
                                state.isFolderPickerPresented = true
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("选择分类目录")
                            .disabled(!state.usePath)
                        }
                        TextField("文件扩展名（空格或逗号分隔）", text: $state.fileTypes)
                        TextField("URL 通配符（空格或换行分隔）", text: $state.urlPatterns)
                    }
                    if let category = state.currentItem {
                        Text("分类 ID：\(category.id) · 已归类 \(category.items.count) 个任务")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("选择一个分类")
                    .font(.headline)
                Text("或使用左下角加号新增")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
