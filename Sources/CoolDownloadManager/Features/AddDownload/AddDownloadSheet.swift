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
    let service: DownloadService?
    let blockAddWhenLoading: Bool
    var integrationItems: [IntegrationDownloadCredential] = []
    let onChooseFolder: () -> Void
    let onCancel: () -> Void
    let onAdd: (_ queueID: DownloadID?, _ categoryID: DownloadID?, _ startImmediately: Bool) -> Void
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case address
        case name
    }

    private var submitTitle: String {
        if submission.isSubmitting { return "正在提交…" }
        if submission.tasksAdded { return "重试保存目录" }
        if !submission.addedIDs.isEmpty { return "继续添加" }
        return startImmediately ? "下载" : "添加"
    }

    @ViewBuilder
    private var previewSection: some View {
        if !submission.previewSources.isEmpty || submission.previewValidationError != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("文件信息").font(DownloadVisualStyle.sectionTitle).foregroundStyle(.secondary)
                    Spacer()
                    if submission.isLoadingPreview {
                        ProgressView().controlSize(.small)
                        Text("正在加载…").font(.caption).foregroundStyle(.secondary)
                    } else if !submission.previewErrors.isEmpty {
                        Button("重试", action: refreshPreview).buttonStyle(.borderless)
                    }
                }
                if let error = submission.previewValidationError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                ForEach(Array(submission.previewSources.indices), id: \.self) { index in
                    if let preview = submission.previews[index] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preview.fileName ?? "名称待下载时确认").lineLimit(1).truncationMode(.middle)
                            if preview.source.kind == .hls {
                                Text("HLS · \(preview.hlsSegmentCount.map { "\($0) 个分片" } ?? "分片待确认") · \(preview.hlsDuration.map { String(format: "%.0f 秒", $0) } ?? "时长未知") · 大小待下载时确认")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("\(preview.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知") · 断点续传：\(ResumeSupportPresentation.text(preview.supportsResume))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if let error = submission.previewErrors[index] {
                        Label(submission.previewSources.count == 1 ? error : "第 \(index + 1) 项：\(error)", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func refreshPreview() {
        guard !submission.isSubmitting, submission.addedIDs.isEmpty else { return }
        do {
            let sources = try DownloadSourceDraft.sources(link: urlText, name: nameText, originals: integrationItems)
            guard let service else { submission.invalidatePreviews(nil); return }
            submission.loadPreviews(sources: sources) { source in try await service.preview(source: source) }
        } catch {
            submission.invalidatePreviews("请检查下载地址及请求头，仅支持有效的 HTTP 或 HTTPS 来源。")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DownloadPanelHeader(
                title: title,
                subtitle: "输入地址并选择下载选项",
                systemImage: "arrow.down.circle.fill",
                tint: .accentColor
            ) { EmptyView() }
            Divider()

            NativePageContent(
                maxWidth: NativePageLayout.compactContentWidth,
                spacing: 20,
                insets: DownloadVisualStyle.formInsets
            ) {
                SettingsSectionView(title: "下载地址", description: "") {
                    TextEditor(text: $urlText)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .scrollContentBackground(.hidden)
                        .frame(height: 76)
                        .padding(10)
                        .focused($focusedField, equals: .address)
                        .modifier(DownloadInputSurface(isFocused: focusedField == .address))
                        .accessibilityLabel("下载地址")
                }

                previewSection

                VStack(alignment: .leading, spacing: 8) {
                    Text("下载选项")
                        .font(DownloadVisualStyle.sectionTitle)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        NativeSettingsRow(title: "文件名", minimumHeight: DownloadVisualStyle.formRowHeight) {
                            TextField(submission.previews[0]?.fileName ?? "自动从地址解析", text: $nameText)
                                .textFieldStyle(.plain)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .focused($focusedField, equals: .name)
                                .modifier(DownloadInputSurface(isFocused: focusedField == .name))
                                .frame(minWidth: 220, idealWidth: 300, maxWidth: 420)
                                .accessibilityLabel("文件名")
                        }
                        NativeSettingsRow(title: "保存位置", minimumHeight: DownloadVisualStyle.formRowHeight) {
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
                                .accessibilityLabel("选择下载目录")
                            }
                        }
                        NativeSettingsRow(title: "默认位置", minimumHeight: DownloadVisualStyle.formRowHeight) {
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
                        NativeSettingsRow(title: "队列", minimumHeight: DownloadVisualStyle.formRowHeight) {
                            Picker("队列", selection: $queueID) {
                                Text("不加入队列").tag(Optional<DownloadID>.none)
                                ForEach(queues, id: \.id) { queue in
                                    Text(queue.name).tag(Optional(queue.id))
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                        }
                        NativeSettingsRow(title: "分类", minimumHeight: DownloadVisualStyle.formRowHeight) {
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
                            showsDivider: false,
                            minimumHeight: DownloadVisualStyle.formRowHeight
                        )
                    }
                }
            }
            .disabled(submission.isSubmitting || !submission.addedIDs.isEmpty)

            if let error = submission.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.05))
            }

            NativePageActionBar {
                Spacer()
                Button(submission.addedIDs.isEmpty ? "取消" : "关闭", action: onCancel)
                    .disabled(submission.isSubmitting)
                    .keyboardShortcut(.cancelAction)
                Button(submitTitle) {
                    submission.cancelPreviews()
                    onAdd(queueID, categoryID, startImmediately)
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(submission.isSubmitting || (!submission.tasksAdded && (urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submission.previewValidationError != nil || (blockAddWhenLoading && submission.isLoadingPreview))))
            }
            .controlSize(.large)
        }
        .modifier(DownloadPanelSurface())
        .interactiveDismissDisabled(submission.isSubmitting)
        .onAppear { refreshPreview() }
        .onChange(of: urlText) { _, updated in
            if integrationItems.count == 1, let hint = integrationItems[0].suggestedName,
               nameText == hint, !DownloadSourceDraft.sameOrigin(updated.trimmingCharacters(in: .whitespacesAndNewlines), integrationItems[0].link) {
                nameText = ""
            }
            refreshPreview()
        }
        .onChange(of: nameText) { _, _ in refreshPreview() }
        .onDisappear { submission.cancelPreviews() }
        .onChange(of: folderURL) { _, folder in
            if !submission.canRemember(folder: folder, defaultFolder: defaultFolder) {
                submission.rememberFolder = false
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 560, idealHeight: 620)
    }
}
