import AppKit
import SwiftUI
import CoolDownloadCore

struct CompletionView: View {
    let record: DownloadRecord
    @ObservedObject var store: DownloadListStore
    @ObservedObject var coordinator: AppCoordinator
    let onClose: () -> Void

    private var currentRecord: DownloadRecord {
        store.record(id: record.id) ?? record
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        fileIcon
                        VStack(alignment: .leading, spacing: 6) {
                            Label("下载完成", systemImage: "checkmark.circle.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.green)
                            Text(currentRecord.name)
                                .font(.headline)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        detailRow("大小", value: sizeText)
                        detailRow("保存位置", value: currentRecord.destinationURL.path, selectable: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack(spacing: 10) {
                Button("打开文件", systemImage: "arrow.up.right.square") {
                    coordinator.openFile(currentRecord)
                    onClose()
                }
                .disabled(currentRecord.status != .completed)

                Button("显示位置", systemImage: "folder") {
                    coordinator.revealFile(currentRecord)
                    onClose()
                }
                .disabled(currentRecord.status != .completed)

                Spacer()

                Button("重新下载", systemImage: "arrow.clockwise") {
                    store.redownload(id: currentRecord.id)
                    onClose()
                }
                .disabled(currentRecord.status != .completed)

                Button("完成") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    }

    private var fileIcon: some View {
        let image = NSWorkspace.shared.icon(forFile: currentRecord.destinationURL.path)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
    }

    private var sizeText: String {
        let byteCount = currentRecord.totalBytes ?? currentRecord.downloadedBytes
        let formatter = ByteCountFormatter()
        formatter.countStyle = coordinator.store.settings.sizeUnit == "DecimalBytes" ? .decimal : .binary
        return ByteCountText.string(fromByteCount: byteCount, formatter: formatter)
    }

    @ViewBuilder
    private func detailRow(_ title: String, value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .lineLimit(2)
            .truncationMode(.middle)
        }
        .font(.callout)
    }
}
