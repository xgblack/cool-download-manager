import AppKit
import SwiftUI
import CoolDownloadCore
import CoolFileActions

struct FileQuickActionButton: View {
    let record: DownloadRecord
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var actions: FileQuickActionController
    var onOpened: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(record: DownloadRecord, coordinator: AppCoordinator, onOpened: (() -> Void)? = nil, onFailure: ((String) -> Void)? = nil) {
        self.record = record
        self.coordinator = coordinator
        _actions = ObservedObject(wrappedValue: coordinator.fileActions)
        self.onOpened = onOpened
        self.onFailure = onFailure
    }

    var body: some View {
        if let kind = FileQuickActionKind.detect(record) {
            if let session = actions.session(for: record) {
                FileQuickSessionButton(session: session, coordinator: coordinator)
            } else {
                Button(kind.title, systemImage: kind.symbol) {
                    if kind == .archive {
                        coordinator.openQuickArchive(record, onOpened: onOpened, onFailure: onFailure)
                    } else {
                        coordinator.startFileQuickAction(record)
                    }
                }
            }
        }
    }
}

private struct FileQuickSessionButton: View {
    @ObservedObject var session: FileQuickActionSession
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Button(session.isRunning ? "查看安装进度" : "查看安装结果", systemImage: session.isRunning ? "ellipsis.circle" : "info.circle") {
            coordinator.fileActions.present(session)
        }
    }
}

struct FileQuickActionView: View {
    @ObservedObject var session: FileQuickActionSession
    @ObservedObject var coordinator: AppCoordinator
    let onClose: () -> Void
    @State private var openError: String?

    var body: some View {
        VStack(spacing: 0) {
            NativePageHeader(title: session.kind == .font ? "字体安装" : "应用安装", subtitle: session.record.name,
                systemImage: session.kind.symbol) {}
            Divider()
            NativePageContent(maxWidth: NativePageLayout.compactContentWidth) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        if session.isRunning, session.prompt == nil { ProgressView().controlSize(.small) }
                        Text(session.message).font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    if let prompt = session.prompt { promptContent(prompt) }
                    if let error = session.error {
                        Label("未能完成安装", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error).textSelection(.enabled)
                    }
                    if let result = session.result {
                        Text(result.destination.path).foregroundStyle(.secondary).textSelection(.enabled)
                        ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            NativePageActionBar {
                if session.kind == .diskImage, !session.isRunning {
                    Button("打开镜像", systemImage: "externaldrive") { coordinator.openFile(session.record) }
                    if session.result != nil {
                        Button("安装其他应用…") {
                            coordinator.startFileQuickAction(session.record)
                            onClose()
                        }
                    }
                }
                if !session.isRunning, session.result == nil {
                    Button("重试", systemImage: "arrow.clockwise") {
                        coordinator.startFileQuickAction(session.record)
                        onClose()
                    }
                }
                Spacer()
                if session.isRunning {
                    Button(session.isCancelling ? "正在取消…" : "取消安装", role: .cancel) { session.cancel() }
                        .disabled(!session.canCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("隐藏窗口", action: onClose)
                } else {
                    Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                }
                if case .replace = session.prompt {
                    Button("替换", role: .destructive) { session.answer(.replace) }
                        .buttonStyle(.borderedProminent)
                }
                if let result = session.result {
                    Button(session.kind == .font ? "查看字体" : "打开应用", systemImage: "arrow.up.right.square") {
                        let application = session.kind == .font
                            ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FontBook") : nil
                        DownloadFileOpener.openURL(result.destination, application: application) { message in openError = message }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 380)
        .alert("无法打开", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("确定", role: .cancel) {}
        } message: { Text(openError ?? "") }
    }

    @ViewBuilder
    private func promptContent(_ prompt: FileActionPrompt) -> some View {
        switch prompt {
        case .permission:
            Text("没有权限写入系统“应用程序”目录。请选择安装方式；取消后不会安装，也不会自动更换位置。")
            VStack(alignment: .leading, spacing: 12) {
                Button("管理员授权安装") { session.answer(.authorize) }.buttonStyle(.borderedProminent)
                Button("仅为当前用户安装") { session.answer(.currentUser) }
                Text("当前用户安装位置：~/Applications").font(.caption).foregroundStyle(.secondary)
            }
        case .replace(let destination, let current, let incoming):
            Text("安装位置已存在同名文件。确认后将替换现有版本。")
            NativeSettingsGroup(title: "替换信息") {
                NativeSettingsRow(title: "现有版本") { Text(current).multilineTextAlignment(.trailing) }
                NativeSettingsRow(title: "安装版本") { Text(incoming).multilineTextAlignment(.trailing) }
                NativeSettingsRow(title: "安装位置", showsDivider: false) {
                    Text(destination.path).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                }
            }
        case .applications(let applications):
            Text("镜像内包含多个应用，请选择本次要安装的应用。")
            ForEach(applications, id: \.self) { application in
                Button { session.answer(.application(application)) } label: {
                    Label(application.lastPathComponent, systemImage: "app")
                }
                .help(application.path)
            }
        }
    }
}
