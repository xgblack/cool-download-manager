import SwiftUI
import CoolDownloadCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List {
                Label("全部下载", systemImage: "arrow.down.circle")
                    .tag("all")
                Label("进行中", systemImage: "arrow.down.circle.fill")
                Label("已完成", systemImage: "checkmark.circle")
                Label("失败", systemImage: "exclamationmark.circle")
            }
            .listStyle(.sidebar)
            .navigationTitle("下载管理器")
        } detail: {
            VStack(spacing: 0) {
                addBar
                Divider()
                downloadList
            }
            .frame(minWidth: 760, minHeight: 480)
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            TextField("粘贴下载地址", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.addAndStart() }
            TextField("文件名（可选）", text: $model.nameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Button {
                model.addAndStart()
            } label: {
                Label("添加并开始", systemImage: "plus.circle.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private var downloadList: some View {
        Group {
            if model.downloads.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("暂无下载")
                        .font(.headline)
                    Text("从上方添加一个下载地址")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.downloads) { record in
                    DownloadRow(record: record)
                        .contextMenu {
                            rowActions(record)
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func rowActions(_ record: DownloadRecord) -> some View {
        switch record.status {
        case .completed:
            Button("删除记录", systemImage: "trash") { model.remove(record) }
        case .downloading, .preparing:
            Button("暂停", systemImage: "pause.fill") { model.pause(record) }
        case .failed:
            Button("重试", systemImage: "arrow.clockwise") { model.retry(record) }
        default:
            Button("开始", systemImage: "play.fill") { model.start(record) }
            Button("删除记录", systemImage: "trash") { model.remove(record) }
        }
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.name)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(record.status.rawValue)
                    Text(byteSummary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if let totalBytes = record.totalBytes, totalBytes > 0 {
                ProgressView(value: Double(record.downloadedBytes), total: Double(totalBytes))
                    .frame(width: 150)
            }
        }
        .padding(.vertical, 5)
    }

    private var iconName: String {
        switch record.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .downloading, .preparing: return "arrow.down.circle.fill"
        default: return "ellipsis.circle"
        }
    }

    private var iconColor: Color {
        switch record.status {
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        default: return .accentColor
        }
    }

    private var byteSummary: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if let total = record.totalBytes {
            return "\(formatter.string(fromByteCount: record.downloadedBytes)) / \(formatter.string(fromByteCount: total))"
        }
        return formatter.string(fromByteCount: record.downloadedBytes)
    }
}
