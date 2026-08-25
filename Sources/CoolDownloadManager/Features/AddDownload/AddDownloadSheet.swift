import SwiftUI
import CoolDownloadCore
import CoolDownloadIntegration

struct AddDownloadSheet: View {
    @Binding var urlText: String
    @Binding var nameText: String
    @Binding var folderURL: URL
    @Binding var queueID: DownloadID?
    @Binding var categoryID: DownloadID?
    @Binding var startImmediately: Bool
    let queues: [IntegrationQueue]
    let categories: [DownloadCategory]
    let onChooseFolder: () -> Void
    let onCancel: () -> Void
    let onAdd: (_ queueID: DownloadID?, _ categoryID: DownloadID?, _ startImmediately: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("新建下载", systemImage: "arrow.down.circle")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("下载地址")
                    .font(.headline)
                TextEditor(text: $urlText)
                    .font(.body.monospaced())
                    .frame(minHeight: 72, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                Text("支持多个 URL，每行一个；浏览器扩展的静默导入使用同一核心入口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                LabeledContent("文件名") {
                    TextField("自动从 URL 解析", text: $nameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(folderURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("选择目录", action: onChooseFolder)
            }

            HStack(spacing: 12) {
                Picker("队列", selection: $queueID) {
                    Text("不加入队列").tag(Optional<DownloadID>.none)
                    ForEach(queues, id: \.id) { queue in
                        Text(queue.name).tag(Optional(queue.id))
                    }
                }
                Picker("分类", selection: $categoryID) {
                    Text("未分类").tag(Optional<DownloadID>.none)
                    ForEach(categories, id: \.id) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                Toggle("立即开始", isOn: $startImmediately)
                    .toggleStyle(.checkbox)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(startImmediately ? "下载" : "添加") {
                    onAdd(queueID, categoryID, startImmediately)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
