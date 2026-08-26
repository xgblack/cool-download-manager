import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoolDownloadCore

struct BatchDownloadView: View {
    let onClose: () -> Void
    let onAdd: (
        _ pattern: String,
        _ start: Int,
        _ end: Int,
        _ wildcardLength: BatchWildcardLength,
        _ folder: URL,
        _ startImmediately: Bool
    ) -> Void
    @ObservedObject private var state: BatchDownloadViewState

    init(
        initialPattern: String = "",
        defaultFolder: URL,
        onClose: @escaping () -> Void,
        onAdd: @escaping (
            _ pattern: String,
            _ start: Int,
            _ end: Int,
            _ wildcardLength: BatchWildcardLength,
            _ folder: URL,
            _ startImmediately: Bool
        ) -> Void
    ) {
        self.onClose = onClose
        self.onAdd = onAdd
        _state = ObservedObject(wrappedValue: BatchDownloadViewState(
            pattern: initialPattern,
            folderURL: defaultFolder
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSectionView(title: "下载地址", description: "使用 * 代表连续编号，例如 photo-*.jpg。") {
                        HStack {
                            TextField("https://example.com/photo-*.jpg", text: $state.pattern)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                if let text = NSPasteboard.general.string(forType: .string) {
                                    state.pattern = text
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .help("从剪贴板粘贴")
                        }
                        if let error = state.validationError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    SettingsSectionView(title: "编号范围", description: "最多一次创建 1000 个任务。") {
                        HStack {
                            TextField("起始", text: $state.startText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("到")
                                .foregroundStyle(.secondary)
                            TextField("结束", text: $state.endText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                        Picker("补零方式", selection: $state.wildcardMode) {
                            Text("自动").tag(BatchWildcardMode.automatic)
                            Text("不补零").tag(BatchWildcardMode.unspecified)
                            Text("自定义").tag(BatchWildcardMode.custom)
                        }
                        if state.wildcardMode == .custom {
                            TextField("位数（1-10）", text: $state.customLengthText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                    }

                    SettingsSectionView(title: "预览", description: "确认首尾链接后再创建任务。") {
                        HStack(spacing: 12) {
                            previewValue(title: "首个", value: state.preview?.first ?? "")
                            previewValue(title: "末个", value: state.preview?.last ?? "")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("数量").font(.caption).foregroundStyle(.secondary)
                                Text(state.preview.map { String($0.count) } ?? "-")
                                    .font(.body.monospacedDigit())
                            }
                        }
                    }

                    SettingsSectionView(title: "保存和启动", description: "批量任务会使用同一个目录和启动策略。") {
                        HStack {
                            TextField("下载目录", text: $state.folderPath)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                state.isFolderPickerPresented = true
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("选择下载目录")
                        }
                        Toggle("创建后立即开始", isOn: $state.startImmediately)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Spacer()
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("添加 \(state.preview?.count ?? 0) 个任务") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.preview == nil)
            }
            .padding(12)
        }
        .frame(width: 720, height: 620)
        .navigationTitle("批量下载")
        .fileImporter(
            isPresented: $state.isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.folderPath = url.path
            }
        }
        .onAppear {
            if state.pattern.isEmpty,
               let clipboard = NSPasteboard.general.string(forType: .string),
               clipboard.contains("*") {
                state.pattern = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func previewValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func confirm() {
        guard let preview = state.preview,
              let start = Int(state.startText),
              let end = Int(state.endText),
              !state.folderPath.isEmpty else {
            return
        }
        let actualFolder = URL(fileURLWithPath: state.folderPath, isDirectory: true)
        guard !preview.isEmpty else { return }
        onAdd(
            state.pattern,
            start,
            end,
            state.wildcardLength,
            actualFolder,
            state.startImmediately
        )
        onClose()
    }
}

private enum BatchWildcardMode: String, CaseIterable, Sendable {
    case automatic
    case unspecified
    case custom
}

@MainActor
private final class BatchDownloadViewState: ObservableObject {
    @Published var pattern: String
    @Published var startText = "1"
    @Published var endText = "10"
    @Published var wildcardMode: BatchWildcardMode = .automatic
    @Published var customLengthText = "2"
    @Published var folderPath: String
    @Published var startImmediately = true
    @Published var isFolderPickerPresented = false

    init(pattern: String, folderURL: URL) {
        self.pattern = pattern
        self.folderPath = folderURL.path
    }

    var wildcardLength: BatchWildcardLength {
        switch wildcardMode {
        case .automatic: return .automatic
        case .unspecified: return .unspecified
        case .custom: return .custom(Int(customLengthText) ?? 0)
        }
    }

    var preview: [String]? {
        guard let start = Int(startText), let end = Int(endText) else { return nil }
        return try? BatchDownloadExpander().expand(
            pattern: pattern,
            start: start,
            end: end,
            wildcardLength: wildcardLength
        )
    }

    var validationError: String? {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let start = Int(startText), let end = Int(endText) else { return "范围必须是整数" }
        do {
            _ = try BatchDownloadExpander().expand(
                pattern: pattern,
                start: start,
                end: end,
                wildcardLength: wildcardLength
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
