import SwiftUI
import CoolDownloadCore

struct CompletionView: View {
    let record: DownloadRecord
    @ObservedObject var store: DownloadListStore
    @ObservedObject var coordinator: AppCoordinator
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                Text("下载完成")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(18)
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text(record.name)
                    .font(.headline)
                    .lineLimit(2)
                LabeledContent("大小") {
                    Text(sizeText)
                }
                LabeledContent("保存位置") {
                    Text(record.destinationURL.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)

            Divider()
            HStack {
                Button("打开文件", systemImage: "arrow.up.right.square") {
                    coordinator.openFile(record)
                    onClose()
                }
                Button("打开所在目录", systemImage: "folder") {
                    coordinator.revealFile(record)
                    onClose()
                }
                Spacer()
                Button("重新下载", systemImage: "arrow.clockwise") {
                    store.selectedIDs = [record.id]
                    store.redownloadSelected()
                    onClose()
                }
                .disabled(record.status != .completed)
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 520, height: 280)
    }

    private var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: record.totalBytes ?? record.downloadedBytes)
    }
}
