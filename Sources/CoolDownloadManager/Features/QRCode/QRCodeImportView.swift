import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoolDownloadCore
import CoolDownloadIntegration

struct QRCodeImportCandidate: Identifiable, Equatable {
    let id: UUID
    let sources: [DownloadSource]

    var title: String {
        sources.count == 1
            ? (sources[0].suggestedName ?? URL(string: sources[0].link)?.host ?? "下载来源")
            : "\(sources.count) 个下载来源"
    }

    var containsCredentials: Bool {
        sources.contains { source in
            source.headers?.isEmpty == false
                || URLComponents(string: source.link)?.user != nil
                || URLComponents(string: source.link)?.password != nil
        }
    }
}

struct QRCodeImportView: View {
    let onImport: ([DownloadSource]) -> Void
    let onClose: () -> Void
    @StateObject private var state = QRCodeImportState()
    @StateObject private var camera = QRCodeCameraController()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            DownloadPanelHeader(
                title: "扫描下载二维码",
                subtitle: "识别后确认来源，再选择下载选项",
                systemImage: "qrcode.viewfinder",
                tint: .accentColor
            ) { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button("选择图片", systemImage: "photo") {
                            camera.stop()
                            chooseImage()
                        }
                        Button("从剪贴板导入", systemImage: "doc.on.clipboard") {
                            camera.stop()
                            state.importPasteboard()
                        }
                        .keyboardShortcut("v", modifiers: .command)
                        Button("使用摄像头", systemImage: "camera") {
                            state.clear()
                            camera.start { texts in state.accept(texts) }
                        }
                        .disabled(camera.state == .requesting || camera.state == .running)
                    }
                    if camera.state == .running {
                        QRCodeCameraPreview(session: camera.session)
                            .frame(height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: DownloadVisualStyle.cornerRadius))
                            .accessibilityLabel("摄像头二维码扫描预览")
                        Button("停止摄像头", systemImage: "stop.circle") { camera.stop() }
                    } else if camera.state == .requesting {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在请求摄像头权限并准备扫描…")
                            Spacer()
                            Button("取消") { camera.stop() }
                        }
                        .font(.callout)
                        .frame(height: 100)
                    } else if case .failed(let message) = camera.state {
                        Label(message, systemImage: "camera.badge.ellipsis")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if state.isReading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在识别图片…").font(.callout)
                        }
                        .frame(maxWidth: .infinity, minHeight: 100)
                    } else if state.candidates.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 42))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text("将二维码图片拖到这里")
                                .font(.headline)
                            Text("也可选择图片、粘贴图片或下载来源文本，或使用摄像头扫描。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(16)
                        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025))
                        .clipShape(RoundedRectangle(cornerRadius: DownloadVisualStyle.cornerRadius))
                    } else {
                        Text("选择要导入的下载来源")
                            .font(DownloadVisualStyle.sectionTitle)
                        ForEach(state.candidates) { candidate in
                            candidateRow(candidate)
                            Divider()
                        }
                        Text("使用后进入下载确认窗口；在确认前不会创建或开始下载。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message = state.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                camera.stop()
                return state.importDrop(providers)
            }
            NativePageActionBar {
                if !state.selectedSources.isEmpty {
                    Text("已选 \(state.selectedSources.count) 个下载来源")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("使用所选来源") {
                    let sources = state.selectedSources
                    guard !sources.isEmpty else { return }
                    camera.stop()
                    state.cancelReading()
                    onImport(sources)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.selectedSources.isEmpty || state.isReading)
            }
        }
        .modifier(DownloadPanelSurface())
        .frame(minWidth: 640, idealWidth: 680, minHeight: 490, idealHeight: 620)
        .onDisappear {
            camera.stop()
            state.cancelReading()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            camera.stop()
            state.cancelReading()
        }
    }

    private func candidateRow(_ candidate: QRCodeImportCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("选择 \(candidate.title)", isOn: Binding(
                get: { state.selectedIDs.contains(candidate.id) },
                set: { value in
                    if value { state.selectedIDs.insert(candidate.id) }
                    else { state.selectedIDs.remove(candidate.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.title).font(.body.weight(.medium))
                ForEach(Array(candidate.sources.enumerated()), id: \.offset) { _, source in
                    Text(source.link)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(source.kind == .hls ? "HLS 视频来源" : "HTTP / HTTPS 文件来源")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if candidate.containsCredentials {
                    Label("包含请求信息，请确认来源可信", systemImage: "key")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            state.importImage(at: url)
        }
    }

    private func close() {
        camera.stop()
        state.cancelReading()
        onClose()
    }
}

@MainActor
final class QRCodeImportState: ObservableObject {
    @Published private(set) var candidates: [QRCodeImportCandidate] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isReading = false
    private var readTask: Task<Void, Never>?
    private var generation = UUID()

    var selectedSources: [DownloadSource] {
        var result: [DownloadSource] = []
        for candidate in candidates where selectedIDs.contains(candidate.id) {
            for source in candidate.sources where !result.contains(source) { result.append(source) }
        }
        return result
    }

    func clear() {
        cancelReading()
        candidates = []
        selectedIDs = []
        errorMessage = nil
    }

    func accept(_ texts: [String]) {
        clear()
        var rejected = 0
        for text in texts {
            do {
                let sources = try DownloadSourceShareCodec.decode(text)
                guard !sources.isEmpty else { rejected += 1; continue }
                guard !candidates.contains(where: { $0.sources == sources }) else { continue }
                candidates.append(QRCodeImportCandidate(id: UUID(), sources: sources))
            } catch {
                rejected += 1
            }
        }
        if let first = candidates.first { selectedIDs = [first.id] }
        if candidates.isEmpty {
            errorMessage = "没有可导入的下载来源。支持 HTTP、HTTPS 链接和下载来源 JSON。"
        } else if rejected > 0 {
            errorMessage = "另有 \(rejected) 个二维码无法作为下载来源，已保留可识别的内容。"
        }
    }

    func importImage(at url: URL) {
        readImage {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: QRCodeReader.maximumImageBytes + 1) ?? Data()
            return try QRCodeReader.read(data)
        }
    }

    func importImage(data: Data) {
        readImage { try QRCodeReader.read(data) }
    }

    func importPasteboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            importImage(at: url)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            importImage(data: data)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            accept([text])
        } else {
            clear()
            errorMessage = "剪贴板中没有图片或下载来源文本。"
        }
    }

    func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
            return false
        }
        clear()
        isReading = true
        let token = generation
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                        self.isReading = false
                        self.errorMessage = "无法读取拖入的图片，请使用“选择图片”。"
                        return
                    }
                    self.importImage(at: url)
                }
            }
        } else {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    guard let data else {
                        self.isReading = false
                        self.errorMessage = "无法读取拖入的图片，请使用“选择图片”。"
                        return
                    }
                    self.importImage(data: data)
                }
            }
        }
        return true
    }

    func cancelReading() {
        generation = UUID()
        readTask?.cancel()
        readTask = nil
        isReading = false
    }

    private func readImage(_ operation: @escaping @Sendable () throws -> [String]) {
        clear()
        let token = generation
        isReading = true
        errorMessage = nil
        readTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try operation()
                }
                let texts = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, !Task.isCancelled, self.generation == token else { return }
                accept(texts)
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                isReading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
