import SwiftUI
import CoolDownloadCore

/// Failure and retry feedback stays independent of Range work and file size.
struct DownloadFailureView: View {
    let record: DownloadRecord

    nonisolated static func isVisible(for status: DownloadStatus) -> Bool {
        status == .failed || status == .waitingForSourceRefresh || status == .retrying
    }

    private var title: String {
        switch record.status {
        case .retrying: return "等待重试"
        case .waitingForSourceRefresh: return "下载已停止，等待更新来源"
        default: return "下载失败，已停止"
        }
    }

    private var message: String {
        record.error ?? "未提供具体错误，请检查下载来源后重试。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: record.status == .retrying ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill")
                    .font(DownloadVisualStyle.sectionTitle)
                    .foregroundStyle(DownloadVisualStyle.tint(for: record.status))
                Spacer()
                Button("复制错误", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if record.status == .retrying {
                Text("正在等待下一次尝试；此时没有传输数据，可暂停此任务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Both status and known size determine whether progress is active or static.
struct DownloadProgressPresentation {
    let record: DownloadRecord

    var fraction: Double? {
        if record.status == .completed { return 1 }
        guard let total = record.totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(record.downloadedBytes) / Double(total)))
    }

    var isIndeterminate: Bool {
        fraction == nil && (record.status == .preparing || record.status == .downloading)
    }

    var statusMessage: String {
        switch record.status {
        case .added: return "等待开始下载"
        case .preparing: return "正在连接并获取文件信息…"
        case .downloading: return "正在下载，文件总大小未知"
        case .paused: return "下载已暂停"
        case .retrying: return "等待重试"
        case .waitingForSourceRefresh: return "等待更新下载来源"
        case .completed: return "下载已完成"
        case .failed: return record.downloadedBytes == 0 ? "未能开始下载" : "下载已中断，已有进度已保留"
        case .cancelled: return "下载已取消"
        }
    }
}
