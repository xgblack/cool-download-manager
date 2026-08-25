import SwiftUI
import CoolDownloadCore

/// Non-modal progress surface shown in an AppKit utility panel.
struct DownloadProgressView: View {
    let record: DownloadRecord
    @ObservedObject var store: DownloadListStore
    @ObservedObject var coordinator: AppCoordinator
    let onClose: () -> Void

    private var currentRecord: DownloadRecord {
        store.record(id: record.id) ?? record
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentRecord.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let total = currentRecord.totalBytes, total > 0 {
                ProgressView(value: Double(currentRecord.downloadedBytes), total: Double(total))
                    .progressViewStyle(.linear)
                HStack {
                    Text(byteFormatter.string(fromByteCount: currentRecord.downloadedBytes))
                    Spacer()
                    Text(byteFormatter.string(fromByteCount: total))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack {
                Text(currentRecord.source.link)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("查看详情", systemImage: "info.circle") {
                    onClose()
                    coordinator.openDetail(for: currentRecord.id)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    private var statusText: String {
        switch currentRecord.status {
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
}
