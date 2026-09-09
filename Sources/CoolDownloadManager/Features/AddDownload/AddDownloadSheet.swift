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
    @ObservedObject var submission: DownloadSubmissionState
    let defaultFolder: URL
    let title: String
    let queues: [IntegrationQueue]
    let categories: [DownloadCategory]
    let onChooseFolder: () -> Void
    let onCancel: () -> Void
    let onAdd: (_ queueID: DownloadID?, _ categoryID: DownloadID?, _ startImmediately: Bool) -> Void

    private var submitTitle: String {
        if submission.isSubmitting { return "正在提交…" }
        if submission.tasksAdded { return "重试保存目录" }
        if !submission.addedIDs.isEmpty { return "继续添加" }
        return startImmediately ? "下载" : "添加"
    }

    var body: some View {
        VStack(spacing: 0) {
            NativePageHeader(
                title: title,
                subtitle: "输入地址并选择下载选项",
                systemImage: "arrow.down.circle.fill",
                tint: .accentColor
            )
            Divider()

            NativePageContent(maxWidth: NativePageLayout.compactContentWidth) {
                SettingsSectionView(title: "下载地址", description: "") {
                    TextEditor(text: $urlText)
                        .font(.body.monospaced())
                        .frame(minHeight: 84, maxHeight: 132)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                        }
                }

                NativeSettingsGroup(title: "下载选项") {
                    NativeSettingsRow(title: "文件名") {
                        TextField("自动从地址解析", text: $nameText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220, idealWidth: 300, maxWidth: 420)
                    }
                    NativeSettingsRow(title: "保存位置") {
                        HStack(spacing: 8) {
                            Text(folderURL.path)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(minWidth: 160, idealWidth: 278, maxWidth: .infinity, alignment: .leading)
                                .help(folderURL.path)
                            Button(action: onChooseFolder) {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("选择下载目录")
                        }
                    }
                    NativeSettingsRow(title: "默认位置") {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("设为默认下载目录", isOn: $submission.rememberFolder)
                                .toggleStyle(.checkbox)
                                .disabled(!submission.canRemember(folder: folderURL, defaultFolder: defaultFolder))
                            Text(submission.canRemember(folder: folderURL, defaultFolder: defaultFolder)
                                 ? "添加成功后，用于后续新建下载；分类目录保持独立"
                                 : "当前已是默认下载目录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    NativeSettingsRow(title: "队列") {
                        Picker("队列", selection: $queueID) {
                            Text("不加入队列").tag(Optional<DownloadID>.none)
                            ForEach(queues, id: \.id) { queue in
                                Text(queue.name).tag(Optional(queue.id))
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                    }
                    NativeSettingsRow(title: "分类") {
                        Picker("分类", selection: $categoryID) {
                            Text("未分类").tag(Optional<DownloadID>.none)
                            ForEach(categories, id: \.id) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                    }
                    NativeSettingsToggleRow(
                        "添加后立即开始",
                        isOn: $startImmediately,
                        showsDivider: false
                    )
                }
            }
            .disabled(submission.isSubmitting || !submission.addedIDs.isEmpty)

            if let error = submission.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            NativePageActionBar {
                Spacer()
                Button(submission.addedIDs.isEmpty ? "取消" : "关闭", action: onCancel)
                    .disabled(submission.isSubmitting)
                    .keyboardShortcut(.cancelAction)
                Button(submitTitle) {
                    onAdd(queueID, categoryID, startImmediately)
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(submission.isSubmitting || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .interactiveDismissDisabled(submission.isSubmitting)
        .onChange(of: folderURL) { _, folder in
            if !submission.canRemember(folder: folder, defaultFolder: defaultFolder) {
                submission.rememberFolder = false
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 560, idealHeight: 620)
    }
}
