import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoolDownloadCore
import CoolDownloadIntegration

struct QRCodeImportCandidate: Identifiable, Equatable {
    let id: UUID
    let sources: [DownloadSource]

    var title: String {
        guard sources.count == 1 else { return "\(sources.count) 个下载来源" }
        if let name = sources[0].suggestedName, !name.isEmpty { return name }
        guard let url = URL(string: sources[0].link) else { return "下载来源" }
        return url.lastPathComponent.isEmpty ? (url.host ?? "下载来源") : url.lastPathComponent
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
    @StateObject private var state: QRCodeImportState
    @StateObject private var camera = QRCodeCameraController()
    @State private var isDropTargeted = false

    init(onImport: @escaping ([DownloadSource]) -> Void, onClose: @escaping () -> Void,
         state: QRCodeImportState = QRCodeImportState()) {
        self.onImport = onImport
        self.onClose = onClose
        _state = StateObject(wrappedValue: state)
    }

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
                            if state.hasIncompleteTransfer { state.cancelReading() } else { state.clear() }
                            camera.start { texts in state.receive(texts) }
                        }
                        .disabled(camera.state == .requesting || camera.state == .running)
                    }
                    if camera.state == .running {
                        QRCodeCameraPreview(session: camera.session, observations: camera.observations)
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

                    if state.collection.total > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(state.collection.isComplete ? "已收齐二维码" : "正在收集二维码", systemImage: state.collection.isComplete ? "checkmark.circle.fill" : "qrcode")
                                    .foregroundStyle(state.collection.isComplete ? DownloadVisualStyle.success : Color.primary)
                                Spacer()
                                Text("已收集 \(state.collection.received) / \(state.collection.total) 帧")
                                    .font(DownloadVisualStyle.numeric)
                                Button("重置") { camera.stop(); state.clear() }
                            }
                            ProgressView(value: Double(state.collection.received), total: Double(state.collection.total))
                                .accessibilityLabel("二维码收集进度")
                            if state.hasIncompleteTransfer {
                                Text("请继续扫描当前组，或添加剩余二维码图片。缺少第 \(state.missingFrameSummary) 帧。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let message = state.successMessage {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(DownloadVisualStyle.success)
                    }
                    if let message = state.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(DownloadVisualStyle.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if state.isReading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在识别图片…").font(.callout)
                        }
                        .frame(maxWidth: .infinity, minHeight: 100)
                    } else if state.candidates.isEmpty && !state.hasIncompleteTransfer {
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
                    } else if !state.candidates.isEmpty {
                        HStack {
                            Text("选择要导入的下载来源").font(DownloadVisualStyle.sectionTitle)
                            Spacer()
                            Button("全选") { state.selectedIDs = Set(state.candidates.map(\.id)) }
                            Button("清除选择") { state.selectedIDs = [] }
                        }
                        ForEach(state.candidates) { candidate in
                            candidateRow(candidate)
                            Divider()
                        }
                        Text("使用后进入下载确认窗口；在确认前不会创建或开始下载。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                .disabled(state.selectedSources.isEmpty || state.isReading || state.hasIncompleteTransfer)
            }
        }
        .modifier(DownloadPanelSurface())
        .frame(minWidth: 640, idealWidth: 680, minHeight: 490, idealHeight: 620)
        .onDisappear {
            camera.stop()
            state.clear()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            camera.stop()
            state.clear()
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
                Text(candidate.title).font(.body.weight(.medium)).lineLimit(2).truncationMode(.middle)
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
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            state.importImages(at: panel.urls)
        }
    }

    private func close() {
        camera.stop()
        state.clear()
        onClose()
    }
}

@MainActor
final class QRCodeImportState: ObservableObject {
    @Published private(set) var candidates: [QRCodeImportCandidate] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var successMessage: String?
    @Published private(set) var isReading = false
    @Published private(set) var collection = DownloadQRCodeCollector()
    private var readTask: Task<Void, Never>?
    private var generation = UUID()

    var hasIncompleteTransfer: Bool { collection.total > 0 && !collection.isComplete }
    var missingFrameSummary: String {
        let received = collection.receivedIndices
        let missing = (0..<collection.total).filter { !received.contains($0) }.map { String($0 + 1) }
        return missing.prefix(8).joined(separator: "、") + (missing.count > 8 ? "等" : "")
    }
    var selectedSources: [DownloadSource] {
        var result: [DownloadSource] = []
        for candidate in candidates where selectedIDs.contains(candidate.id) {
            for source in candidate.sources where !result.contains(source) { result.append(source) }
        }
        return result
    }

    func clear() {
        cancelReading()
        collection.reset()
        candidates = []
        selectedIDs = []
        errorMessage = nil
        successMessage = nil
    }

    /// A new independent input, retained for clipboard text and callers that
    /// intentionally replace the previous selection.
    func accept(_ texts: [String]) {
        clear()
        _ = receive(texts)
    }

    /// Incremental camera/image delivery. Progress survives additional inputs.
    /// The camera stops only after valid source content is complete.
    @discardableResult
    func receive(_ texts: [String]) -> Bool {
        var rejected = 0
        var failure: String?
        var accepted = false
        for text in texts {
            do {
                guard let payload = try collection.receive(text) else { continue }
                let sources = try DownloadSourceShareCodec.decode(payload)
                for source in sources where !candidates.contains(where: { $0.sources == [source] }) {
                    candidates.append(QRCodeImportCandidate(id: UUID(), sources: [source]))
                }
                accepted = true
                successMessage = collection.isComplete
                    ? "已收齐 \(collection.total) 帧，识别到 \(sources.count) 个下载来源。"
                    : "已识别下载来源，请选择要使用的内容。"
            } catch {
                rejected += 1
                failure = (error as? DownloadQRCodeError)?.errorDescription
                // An assembled but invalid payload must not lock the scanner
                // onto an unusable finished transfer.
                if collection.isComplete && candidates.isEmpty { collection.reset() }
            }
        }
        if selectedIDs.isEmpty, let first = candidates.first { selectedIDs = [first.id] }
        if rejected > 0 {
            errorMessage = failure ?? (candidates.isEmpty
                ? "没有可导入的下载来源。支持 HTTP、HTTPS 链接和下载来源 JSON。"
                : "另有 \(rejected) 个二维码无法作为下载来源，已保留可识别的内容。")
        } else if !texts.isEmpty { errorMessage = nil }
        return accepted && !hasIncompleteTransfer
    }

    func importImage(at url: URL) { importImages(at: [url]) }
    func importImages(at urls: [URL]) { readInputs(urls.map(ImageInput.url)) }
    func importImage(data: Data) { readInputs([.data(data)]) }

    func importPasteboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            importImages(at: urls)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            importImage(data: data)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            if hasIncompleteTransfer { _ = receive([text]) } else { accept([text]) }
        } else {
            errorMessage = "剪贴板中没有图片或下载来源文本。"
        }
    }

    func importDrop(_ providers: [NSItemProvider]) -> Bool {
        let images = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !images.isEmpty else { return false }
        readInputs(images.map(ImageInput.provider))
        return true
    }

    func cancelReading() {
        generation = UUID()
        readTask?.cancel()
        readTask = nil
        isReading = false
    }

    private enum ImageInput {
        case url(URL)
        case data(Data)
        case provider(NSItemProvider)
    }

    private func readInputs(_ inputs: [ImageInput]) {
        guard !inputs.isEmpty else { return }
        guard inputs.count <= DownloadQRCodeTransfer.maximumFrames else {
            errorMessage = "一次最多导入 \(DownloadQRCodeTransfer.maximumFrames) 张二维码图片，请分批添加。"
            return
        }
        if hasIncompleteTransfer { cancelReading() } else { clear() }
        let token = generation
        isReading = true
        errorMessage = nil
        readTask = Task { [weak self] in
            var imageFailures = 0
            var imageFailureMessage: String?
            for input in inputs {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                do {
                    let operation = try await self.operation(for: input)
                    try Task.checkCancellation()
                    let worker = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        return try operation()
                    }
                    let texts = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, self.generation == token else { return }
                    _ = self.receive(texts)
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    imageFailures += 1
                    imageFailureMessage = (error as? QRCodeError)?.errorDescription ?? "无法读取二维码图片，请检查文件权限或改用其他图片。"
                }
            }
            guard let self, self.generation == token else { return }
            self.isReading = false
            self.readTask = nil
            if imageFailures > 0 {
                self.errorMessage = "有 \(imageFailures) 张图片未能识别，已保留其他图片的识别结果。" + (imageFailureMessage ?? "")
            }
        }
    }

    private func operation(for input: ImageInput) async throws -> @Sendable () throws -> [String] {
        switch input {
        case .url(let url):
            guard url.isFileURL else { throw QRCodeError.imageUnreadable }
            return {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: QRCodeReader.maximumImageBytes + 1) ?? Data()
                return try QRCodeReader.read(data)
            }
        case .data(let data): return { try QRCodeReader.read(data) }
        case .provider(let provider):
            let isURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            let type = isURL ? UTType.fileURL.identifier : UTType.image.identifier
            let data = await QRCodeProviderLoad().read(provider, type: type)
            guard let data else { throw QRCodeError.imageUnreadable }
            if isURL {
                guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { throw QRCodeError.imageUnreadable }
                return try await operation(for: .url(url))
            }
            return { try QRCodeReader.read(data) }
        }
    }
}

/// NSItemProvider may wait for a remote file. Finish the continuation on
/// cancellation as well as cancelling its Progress; late callbacks are ignored.
private final class QRCodeProviderLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var progress: Progress?
    private var completed = false
    private var cancelled = false

    @MainActor
    func read(_ provider: NSItemProvider, type: String) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldStart = lock.withLock {
                    guard !completed else { return false }
                    self.continuation = continuation
                    return true
                }
                guard shouldStart else { continuation.resume(returning: nil); return }
                let progress = provider.loadDataRepresentation(forTypeIdentifier: type) { [self] data, _ in
                    finish(data)
                }
                let shouldCancel = lock.withLock {
                    if !completed { self.progress = progress }
                    return cancelled
                }
                if shouldCancel { progress.cancel() }
            }
        } onCancel: { self.cancel() }
    }

    private func finish(_ data: Data?) {
        let continuation = lock.withLock {
            guard !completed else { return nil as CheckedContinuation<Data?, Never>? }
            completed = true
            let result = self.continuation
            self.continuation = nil
            progress = nil
            return result
        }
        continuation?.resume(returning: data)
    }

    private func cancel() {
        let pending = lock.withLock {
            cancelled = true
            guard !completed else { return (nil as CheckedContinuation<Data?, Never>?, nil as Progress?) }
            completed = true
            let result = (continuation, progress)
            continuation = nil
            progress = nil
            return result
        }
        pending.1?.cancel()
        pending.0?.resume(returning: nil)
    }
}
