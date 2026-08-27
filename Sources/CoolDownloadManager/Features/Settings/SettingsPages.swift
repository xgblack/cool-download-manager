import SwiftUI
import AppKit

private enum SettingsLayout {
    static let contentWidth: CGFloat = 780
    static let labelWidth: CGFloat = 232
    static let rowHeight: CGFloat = 50
    static let groupRadius: CGFloat = 8
}

struct GeneralSettingsPage: View {
    @ObservedObject var store: AppStore
    @ObservedObject var state: SettingsViewState

    var body: some View {
        SettingsPage {
            NativeSettingsGroup(title: "外观") {
                NativeSettingsRow(title: "主题") {
                    Picker("主题", selection: state.binding(\.theme)) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 238)
                }
                NativeSettingsRow(title: "界面缩放", showsDivider: false) {
                    HStack(spacing: 12) {
                        Slider(
                            value: state.optionalDoubleBinding(\.uiScale, defaultValue: 1),
                            in: 0.75...2,
                            step: 0.05
                        )
                        .frame(width: 220)
                        Text(String(format: "%.0f%%", (state.model.uiScale ?? 1) * 100))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }

            NativeSettingsGroup(title: "窗口") {
                NativeSettingsToggleRow(
                    "合并标题栏和顶部工具栏",
                    isOn: state.binding(\.mergeTopBarWithTitleBar)
                )
                NativeSettingsToggleRow(
                    "显示工具栏图标标签",
                    isOn: state.binding(\.showIconLabels)
                )
                NativeSettingsToggleRow(
                    "使用相对日期时间",
                    isOn: state.binding(\.useRelativeDateTime),
                    showsDivider: false
                )
            }

            NativeSettingsGroup(title: "单位") {
                NativeSettingsRow(title: "文件大小") {
                    Picker("文件大小", selection: state.binding(\.sizeUnit)) {
                        Text("二进制（KiB、MiB）").tag("BinaryBytes")
                        Text("十进制（kB、MB）").tag("DecimalBytes")
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                NativeSettingsRow(title: "传输速度") {
                    Picker("传输速度", selection: state.binding(\.speedUnit)) {
                        Text("二进制（MiB/s）").tag("BinaryBytes")
                        Text("十进制（MB/s）").tag("DecimalBytes")
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                NativeSettingsToggleRow(
                    "使用平均速度",
                    isOn: state.binding(\.useAverageSpeed),
                    showsDivider: false
                )
            }

            NativeSettingsGroup(title: "系统") {
                NativeSettingsToggleRow(
                    "开机启动",
                    isOn: state.binding(\.autoStartOnBoot)
                )
                NativeSettingsRow(title: "登录项状态", showsDivider: false) {
                    Label(
                        store.autoStartStatusTitle,
                        systemImage: store.autoStartStatus == .enabled
                            ? "checkmark.circle.fill"
                            : "minus.circle"
                    )
                    .foregroundStyle(store.autoStartStatus == .enabled ? .green : .secondary)
                }
            }
        }
    }
}

struct DownloadSettingsPage: View {
    @ObservedObject var state: SettingsViewState
    let onChooseFolder: () -> Void

    var body: some View {
        SettingsPage {
            NativeSettingsGroup(title: "保存位置") {
                NativeSettingsRow(title: "默认下载目录") {
                    HStack(spacing: 8) {
                        TextField("下载目录", text: state.binding(\.defaultDownloadFolder))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 340)
                        Button(action: onChooseFolder) {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("选择下载目录")
                    }
                }
                NativeSettingsToggleRow(
                    "默认使用分类",
                    isOn: state.binding(\.useCategoryByDefault),
                    showsDivider: false
                )
            }

            NativeSettingsGroup(title: "调度") {
                NativeSettingsNumberRow(
                    "分段线程数",
                    value: state.intBinding(\.threadCount, range: 1...64),
                    range: 1...64
                )
                NativeSettingsNumberRow(
                    "最大并发下载数",
                    value: state.intBinding(\.maxConcurrentDownloads, range: 0...256),
                    range: 0...256
                )
                NativeSettingsNumberRow(
                    "最大重试次数",
                    value: state.intBinding(\.maxDownloadRetryCount, range: 0...100),
                    range: 0...100
                )
                NativeSettingsInt64Row(
                    "全局速度限制",
                    value: state.int64Binding(\.speedLimit, range: 0...Int64.max),
                    range: 0...Int64.max,
                    suffix: "字节/秒"
                )
                NativeSettingsToggleRow(
                    "动态创建分段",
                    isOn: state.binding(\.dynamicPartCreation),
                    showsDivider: false
                )
            }

            NativeSettingsGroup(title: "文件处理") {
                NativeSettingsToggleRow(
                    "给未完成文件追加扩展名",
                    isOn: state.binding(\.appendExtensionToIncompleteDownloads)
                )
                NativeSettingsToggleRow(
                    "使用稀疏文件分配",
                    isOn: state.binding(\.useSparseFileAllocation)
                )
                NativeSettingsToggleRow(
                    "取消下载时删除临时文件",
                    isOn: state.binding(\.deletePartialFileOnDownloadCancellation)
                )
                NativeSettingsToggleRow(
                    "使用服务器 Last-Modified 时间",
                    isOn: state.binding(\.useServerLastModifiedTime),
                    showsDivider: false
                )
            }
        }
    }
}

struct NetworkSettingsPage: View {
    @ObservedObject var state: SettingsViewState
    let onOpenPerHostSettings: () -> Void

    var body: some View {
        SettingsPage {
            NativeSettingsGroup(title: "浏览器连接") {
                NativeSettingsToggleRow(
                    "启用浏览器连接",
                    isOn: state.binding(\.apiEnabled),
                    showsDivider: state.model.apiEnabled
                )
                if state.model.apiEnabled {
                    NativeSettingsNumberRow(
                        "监听端口",
                        value: state.intBinding(\.apiPort, range: 1...65_535),
                        range: 1...65_535
                    )
                    NativeSettingsToggleRow(
                        "启用访问认证",
                        isOn: state.binding(\.apiAuthEnabled),
                        showsDivider: state.model.apiAuthEnabled
                    )
                    if state.model.apiAuthEnabled {
                        NativeSettingsRow(title: "认证密钥", showsDivider: false) {
                            HStack(spacing: 8) {
                                SecureField("认证密钥", text: state.binding(\.apiAuthKey))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 250)
                                Button {
                                    state.regenerateAPIKey()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("重新生成密钥")
                            }
                        }
                    }
                }
            }

            proxyGroup

            NativeSettingsGroup(title: "连接") {
                NativeSettingsFieldRow(
                    "客户端标识 User-Agent",
                    text: state.binding(\.userAgent),
                    placeholder: "留空使用默认值"
                )
                NativeSettingsToggleRow(
                    "忽略 SSL 证书错误",
                    isOn: state.binding(\.ignoreSSLCertificates),
                    showsDivider: false
                )
            }

            NativeSettingsGroup(title: "每主机设置") {
                NativeSettingsDisclosureRow(
                    title: "管理每主机连接和限速",
                    systemImage: "server.rack",
                    action: onOpenPerHostSettings
                )
            }
        }
    }

    private var proxyGroup: some View {
        NativeSettingsGroup(title: "代理") {
            NativeSettingsRow(
                title: "代理模式",
                showsDivider: state.model.proxyMode == "manual" || state.model.proxyMode == "pac"
            ) {
                Picker("代理模式", selection: state.binding(\.proxyMode)) {
                    Text("系统代理").tag("system")
                    Text("直连").tag("direct")
                    Text("手动代理").tag("manual")
                    Text("PAC").tag("pac")
                }
                .labelsHidden()
                .frame(width: 180)
            }
            if state.model.proxyMode == "manual" {
                NativeSettingsFieldRow(
                    "代理主机",
                    text: state.binding(\.proxyHost),
                    placeholder: "主机名或 IP 地址"
                )
                NativeSettingsNumberRow(
                    "代理端口",
                    value: state.intBinding(\.proxyPort, range: 1...65_535),
                    range: 1...65_535
                )
                NativeSettingsFieldRow(
                    "代理用户名",
                    text: state.binding(\.proxyUsername),
                    placeholder: "可选"
                )
                NativeSettingsRow(title: "代理密码", showsDivider: false) {
                    SecureField("可选", text: state.binding(\.proxyPassword))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
            } else if state.model.proxyMode == "pac" {
                NativeSettingsFieldRow(
                    "PAC 地址",
                    text: state.binding(\.proxyPACURL),
                    placeholder: "https://example.com/proxy.pac",
                    showsDivider: false
                )
            }
        }
    }
}

struct NotificationSettingsPage: View {
    @ObservedObject var state: SettingsViewState

    var body: some View {
        SettingsPage {
            NativeSettingsGroup(title: "声音") {
                NativeSettingsToggleRow(
                    "启用通知声音",
                    isOn: state.binding(\.notificationSound),
                    showsDivider: state.model.notificationSound
                )
                if state.model.notificationSound {
                    NativeSettingsFieldRow(
                        "普通通知声音",
                        text: state.binding(\.generalNotificationSound),
                        placeholder: "系统声音名称"
                    )
                    NativeSettingsFieldRow(
                        "错误通知声音",
                        text: state.binding(\.errorNotificationSound),
                        placeholder: "系统声音名称"
                    )
                    NativeSettingsFieldRow(
                        "完成通知声音",
                        text: state.binding(\.successNotificationSound),
                        placeholder: "系统声音名称",
                        showsDivider: false
                    )
                }
            }

            NativeSettingsGroup(title: "下载进度") {
                NativeSettingsToggleRow(
                    "显示下载进度窗口",
                    isOn: state.binding(\.showDownloadProgressDialog),
                    showsDivider: state.model.showDownloadProgressDialog
                )
                if state.model.showDownloadProgressDialog {
                    NativeSettingsToggleRow(
                        "下载开始时自动聚焦",
                        isOn: state.binding(\.focusDownloadProgressDialogOnStart),
                        showsDivider: false
                    )
                }
            }

            NativeSettingsGroup(title: "下载完成") {
                NativeSettingsToggleRow(
                    "显示下载完成窗口",
                    isOn: state.binding(\.showDownloadCompletionDialog),
                    showsDivider: state.model.showDownloadCompletionDialog
                )
                if state.model.showDownloadCompletionDialog {
                    NativeSettingsToggleRow(
                        "下载完成时自动聚焦",
                        isOn: state.binding(\.focusDownloadCompletionDialogOnFinish),
                        showsDivider: false
                    )
                }
            }
        }
    }
}

struct AdvancedSettingsPage: View {
    @ObservedObject var state: SettingsViewState

    var body: some View {
        SettingsPage {
            NativeSettingsGroup(title: "文件一致性") {
                NativeSettingsToggleRow(
                    "跟踪磁盘上被删除的文件",
                    isOn: state.binding(\.trackDeletedFilesOnDisk),
                    showsDivider: false
                )
            }
        }
    }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content()
            }
            .frame(maxWidth: SettingsLayout.contentWidth, alignment: .topLeading)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Shared grouped surface used by the other task editors (queues, categories
/// and batch downloads). It intentionally shares the settings page's spacing
/// and material without coupling those editors to `SettingsView` state.
struct SettingsSectionView<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SettingsLayout.groupRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsLayout.groupRadius, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 0.5)
            }
        }
    }
}

struct NativeSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 1)
            VStack(spacing: 0) {
                content()
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SettingsLayout.groupRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsLayout.groupRadius, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 0.5)
            }
        }
    }
}

struct NativeSettingsRow<Content: View>: View {
    let title: String
    let showsDivider: Bool
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        showsDivider: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.showsDivider = showsDivider
        self.content = content
    }

    var body: some View {
        HStack(spacing: 18) {
            Text(title)
                .font(.body)
                .frame(minWidth: SettingsLayout.labelWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 10)
            content()
        }
        .padding(.horizontal, 18)
        .frame(minHeight: SettingsLayout.rowHeight)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
                    .padding(.leading, 18)
            }
        }
    }
}

struct NativeSettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let showsDivider: Bool

    init(_ title: String, isOn: Binding<Bool>, showsDivider: Bool = true) {
        self.title = title
        _isOn = isOn
        self.showsDivider = showsDivider
    }

    var body: some View {
        NativeSettingsRow(title: title, showsDivider: showsDivider) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct NativeSettingsFieldRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let showsDivider: Bool

    init(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        showsDivider: Bool = true
    ) {
        self.title = title
        _text = text
        self.placeholder = placeholder
        self.showsDivider = showsDivider
    }

    var body: some View {
        NativeSettingsRow(title: title, showsDivider: showsDivider) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 310)
        }
    }
}

struct NativeSettingsNumberRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let fieldWidth: CGFloat
    let suffix: String?
    let showsDivider: Bool

    init(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        fieldWidth: CGFloat = 78,
        suffix: String? = nil,
        showsDivider: Bool = true
    ) {
        self.title = title
        _value = value
        self.range = range
        self.fieldWidth = fieldWidth
        self.suffix = suffix
        self.showsDivider = showsDivider
    }

    var body: some View {
        NativeSettingsRow(title: title, showsDivider: showsDivider) {
            HStack(spacing: 8) {
                TextField("", value: $value, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: fieldWidth)
                    .accessibilityLabel(Text(title))
                Stepper("调整\(title)", value: $value, in: range, step: 1)
                    .labelsHidden()
                    .controlSize(.regular)
                if let suffix {
                    Text(suffix)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
    }
}

struct NativeSettingsInt64Row: View {
    let title: String
    @Binding var value: Int64
    let range: ClosedRange<Int64>
    let fieldWidth: CGFloat
    let suffix: String?
    let showsDivider: Bool

    init(
        _ title: String,
        value: Binding<Int64>,
        range: ClosedRange<Int64>,
        fieldWidth: CGFloat = 120,
        suffix: String? = nil,
        showsDivider: Bool = true
    ) {
        self.title = title
        _value = value
        self.range = range
        self.fieldWidth = fieldWidth
        self.suffix = suffix
        self.showsDivider = showsDivider
    }

    var body: some View {
        NativeSettingsRow(title: title, showsDivider: showsDivider) {
            HStack(spacing: 8) {
                TextField("", value: $value, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: fieldWidth)
                    .accessibilityLabel(Text(title))
                Stepper("调整\(title)", value: $value, in: range, step: 1)
                    .labelsHidden()
                    .controlSize(.regular)
                if let suffix {
                    Text(suffix)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
    }
}

struct NativeSettingsDisclosureRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: SettingsLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsSidebarIcon: View {
    let section: SettingsSection

    var body: some View {
        Image(systemName: section.systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(section.tint)
            .frame(width: 28, height: 28)
            .background(section.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsActionBar: View {
    let isSaving: Bool
    let onReset: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("恢复默认", action: onReset)
                .buttonStyle(.bordered)
            Button(action: onSave) {
                Text(isSaving ? "保存中…" : "保存")
                    .frame(minWidth: 58)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving)
            .controlSize(.regular)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .frame(height: SettingsWindowLayout.actionBarHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
