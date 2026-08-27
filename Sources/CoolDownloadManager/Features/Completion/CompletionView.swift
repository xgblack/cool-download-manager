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
            header
            Divider()
            NativePageContent(maxWidth: NativePageLayout.compactContentWidth) {
                NativeSettingsGroup(title: "下载信息") {
                    NativeSettingsRow(title: "文件大小") {
                        Text(sizeText)
                            .monospacedDigit()
                    }
                    NativeSettingsRow(title: "保存位置", showsDivider: false) {
                        Text(currentRecord.destinationURL.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 280, alignment: .trailing)
                    }
                }
            }
            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 580, maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                fileIcon
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("下载完成")
                    .font(.title2.weight(.semibold))
                Text(currentRecord.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.bar)
    }

    private var actionBar: some View {
        NativePageActionBar {
            Button("重新下载", systemImage: "arrow.clockwise") {
                store.redownload(id: currentRecord.id)
                onClose()
            }
            .disabled(currentRecord.status != .completed)

            Spacer()

            Button("完成") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)

            Button("显示位置", systemImage: "folder") {
                coordinator.revealFile(currentRecord)
                onClose()
            }
            .disabled(currentRecord.status != .completed)

            Button("打开文件", systemImage: "arrow.up.right.square") {
                coordinator.openFile(currentRecord)
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentRecord.status != .completed)
        }
    }

    private var fileIcon: some View {
        let image = NSWorkspace.shared.icon(forFile: currentRecord.destinationURL.path)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
    }

    private var sizeText: String {
        let byteCount = currentRecord.totalBytes ?? currentRecord.downloadedBytes
        let formatter = ByteCountFormatter()
        formatter.countStyle = coordinator.store.settings.sizeUnit == "DecimalBytes" ? .decimal : .binary
        return ByteCountText.string(fromByteCount: byteCount, formatter: formatter)
    }

}
