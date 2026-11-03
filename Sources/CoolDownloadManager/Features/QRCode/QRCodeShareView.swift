import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoolDownloadCore
import CoolDownloadIntegration

struct QRCodeShareView: View {
    let onClose: () -> Void
    @StateObject private var state: QRCodeShareState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(records: [DownloadRecord], onClose: @escaping () -> Void) {
        self.onClose = onClose
        _state = StateObject(wrappedValue: QRCodeShareState(records: records))
    }

    var body: some View {
        VStack(spacing: 0) {
            DownloadPanelHeader(title: "分享下载二维码", subtitle: state.title,
                systemImage: "qrcode", tint: .accentColor) { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("分享内容", selection: $state.mode) {
                        Text("仅分享链接").tag(QRCodeShareState.Mode.link)
                        Text("完整下载来源").tag(QRCodeShareState.Mode.source)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: state.mode) { _, _ in state.refresh() }
                    Text(state.mode == .link
                         ? "分享所选任务的原始链接，链接中的临时签名也会随之分享。"
                         : "包含所选任务保存的请求头和下载页面，可能含有 Cookie 或访问令牌。仅向可信设备分享。")
                        .font(.callout)
                        .foregroundStyle(state.mode == .source ? DownloadVisualStyle.warning : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    qrImage
                    if state.frames.count > 1 {
                        HStack {
                            Button("上一帧", systemImage: "chevron.left") { state.selectFrame(state.currentIndex - 1) }
                                .labelStyle(.iconOnly)
                            Button(state.isPlaying ? "暂停轮播" : "播放轮播", systemImage: state.isPlaying ? "pause.fill" : "play.fill") {
                                state.togglePlayback()
                            }
                            Button("下一帧", systemImage: "chevron.right") { state.selectFrame(state.currentIndex + 1) }
                                .labelStyle(.iconOnly)
                            Spacer()
                            Text("第 \(state.displayedIndex + 1) / \(state.frames.count) 帧")
                                .font(DownloadVisualStyle.numeric)
                                .accessibilityLabel("当前二维码第 \(state.displayedIndex + 1) 帧，共 \(state.frames.count) 帧")
                        }
                        Text("请在接收设备上持续扫描，直至收齐全部 \(state.frames.count) 帧。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = state.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(DownloadVisualStyle.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if state.records.count == 1, let record = state.records.first {
                        Text(record.source.link)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    }
                    HStack {
                        Button(state.frames.count > 1 ? "复制当前图片" : "复制图片", systemImage: "doc.on.doc") { state.copyImage() }
                            .disabled(state.image == nil)
                        Button(state.frames.count > 1 ? "保存全部二维码" : "保存 PNG", systemImage: "square.and.arrow.down") { state.saveImages() }
                            .disabled(state.frames.isEmpty || (state.frames.count == 1 && state.image == nil) || state.isExporting)
                        Button("复制来源文本", systemImage: "text.document") { state.copyText() }
                            .disabled(state.payload == nil)
                    }
                    if state.isExporting { ProgressView("正在保存全部二维码…").controlSize(.small) }
                    if let notice = state.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(20)
            }
            NativePageActionBar {
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .modifier(DownloadPanelSurface())
        .frame(minWidth: 580, idealWidth: 640, minHeight: 700, idealHeight: 740)
        .onAppear { state.setAutomaticPlayback(!reduceMotion) }
        .onChange(of: reduceMotion) { _, value in state.setAutomaticPlayback(!value) }
        .onDisappear { state.cancelRendering() }
    }

    private var qrImage: some View {
        ZStack {
            Color.white
            if let image = state.image {
                GeometryReader { geometry in
                    let scale = max(1, floor(min(geometry.size.width, geometry.size.height) / CGFloat(image.dimensionInModules)))
                    let side = scale * CGFloat(image.dimensionInModules)
                    Image(nsImage: NSImage(cgImage: image.cgImage, size: NSSize(width: image.cgImage.width, height: image.cgImage.height)))
                        .interpolation(.none).resizable()
                        .frame(width: side, height: side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("\(state.title) 的下载二维码，第 \(state.displayedIndex + 1) 帧")
                }
                .padding(12)
            } else if state.isRendering {
                ProgressView("正在生成二维码…").foregroundStyle(.black)
            } else {
                Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(.gray).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: DownloadVisualStyle.cornerRadius))
    }
}

@MainActor
final class QRCodeShareState: ObservableObject {
    enum Mode: Hashable { case link, source }
    let records: [DownloadRecord]
    var title: String { records.count == 1 ? records[0].name : "\(records.count) 个下载来源" }
    @Published var mode: Mode = .link
    @Published private(set) var image: QRCodeImage?
    @Published private(set) var payload: String?
    @Published private(set) var frames: [String] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var displayedIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var isRendering = false
    @Published private(set) var isExporting = false
    private var automaticallyPlays = false
    private var renderTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var generation = UUID()

    init(records: [DownloadRecord]) {
        self.records = records
        refresh()
    }

    func refresh() {
        pause()
        frames = []
        currentIndex = 0
        displayedIndex = 0
        image = nil
        notice = nil
        errorMessage = nil
        do {
            let text: String
            switch mode {
            case .link:
                if records.count == 1 {
                    text = records[0].source.link
                } else {
                    // A source array stays interoperable with upstream while
                    // link-only mode never includes task headers or page data.
                    text = try DownloadSourceShareCodec.encode(records.map {
                        DownloadSource(kind: $0.source.kind, link: $0.source.link)
                    })
                }
            case .source: text = try DownloadSourceShareCodec.encode(records.map(\.source))
            }
            payload = text
            frames = try DownloadQRCodeTransfer.frames(for: text)
            renderCurrentFrame()
            if automaticallyPlays { play() }
        } catch {
            renderTask?.cancel()
            generation = UUID()
            isRendering = false
            // Preserve a valid full payload if only the QR frame limit failed.
            if !(error is DownloadQRCodeError) { payload = nil }
            errorMessage = error.localizedDescription
        }
    }

    func selectFrame(_ index: Int) {
        pause()
        advance(to: index)
    }

    func setAutomaticPlayback(_ enabled: Bool) {
        automaticallyPlays = enabled
        if enabled { play() } else { pause() }
    }

    func togglePlayback() { if isPlaying { pause() } else { play() } }

    private func advance(to index: Int) {
        guard !frames.isEmpty else { return }
        currentIndex = (index % frames.count + frames.count) % frames.count
        renderCurrentFrame()
    }

    private func play() {
        guard frames.count > 1, !isPlaying else { return }
        isPlaying = true
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, !Task.isCancelled, self.isPlaying else { return }
                if !self.isRendering { self.advance(to: self.currentIndex + 1) }
            }
        }
    }

    private func pause() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    private func renderCurrentFrame() {
        renderTask?.cancel()
        let token = UUID()
        generation = token
        guard frames.indices.contains(currentIndex) else { isRendering = false; return }
        let index = currentIndex
        let text = frames[index]
        isRendering = true
        renderTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try QRCodeRenderer.render(text)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, generation == token else { return }
                image = result
                displayedIndex = index
                isRendering = false
            } catch {
                guard let self, !Task.isCancelled, generation == token else { return }
                pause()
                errorMessage = error.localizedDescription
                isRendering = false
            }
        }
    }

    func cancelRendering() {
        pause()
        generation = UUID()
        renderTask?.cancel()
        renderTask = nil
        exportTask?.cancel()
        exportTask = nil
        isRendering = false
        isExporting = false
    }

    func copyText() {
        guard let payload else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(payload, forType: .string) else {
            errorMessage = "无法写入剪贴板，请重试。"; return
        }
        notice = "已复制完整来源文本"
    }

    func copyImage() {
        guard let image else { return }
        pause()
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(image.pngData, forType: .png) else {
            errorMessage = "无法将图片写入剪贴板，请重试。"; return
        }
        notice = frames.count > 1 ? "已复制第 \(displayedIndex + 1) 帧，接收时需收齐全部 \(frames.count) 帧" : "已复制二维码图片"
    }

    func saveImages() {
        pause()
        guard !frames.isEmpty else { return }
        if frames.count == 1 { saveSingleImage(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "保存全部二维码"
        panel.message = "将在所选目录中新建文件夹，按帧序号保存全部 PNG 图片。"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let directory = panel.url else { return }
            let frames = self.frames
            self.isExporting = true
            self.exportTask = Task { [weak self] in
                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        try Self.exportImages(frames, in: directory)
                    }
                    let folder = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard let self, !Task.isCancelled else { return }
                    self.isExporting = false
                    self.notice = "已保存全部 \(frames.count) 帧至 \(folder.lastPathComponent)"
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.isExporting = false
                    self.errorMessage = "二维码保存未完成。已写入的图片保留在新建文件夹中，请检查目录权限或可用空间后重试。"
                }
            }
        }
    }

    nonisolated static func exportImages(_ frames: [String], in directory: URL) throws -> URL {
        guard !frames.isEmpty else { throw DownloadQRCodeError.empty }
        let folder = directory.appendingPathComponent("下载二维码-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for (index, text) in frames.enumerated() {
            try Task.checkCancellation()
            let data = try QRCodeRenderer.render(text).pngData
            try data.write(to: folder.appendingPathComponent(String(format: "二维码-%03d.png", index + 1)), options: .withoutOverwriting)
        }
        return folder
    }

    private func saveSingleImage() {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (title as NSString).lastPathComponent + "-二维码.png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try image.pngData.write(to: url, options: .atomic)
                self?.notice = "二维码图片已保存"
            } catch {
                self?.errorMessage = "无法保存二维码图片，请检查目录权限或可用空间后重试。"
            }
        }
    }
}
