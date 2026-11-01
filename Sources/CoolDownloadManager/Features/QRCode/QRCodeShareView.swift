import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoolDownloadCore
import CoolDownloadIntegration

struct QRCodeShareView: View {
    let onClose: () -> Void
    @StateObject private var state: QRCodeShareState

    init(record: DownloadRecord, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _state = StateObject(wrappedValue: QRCodeShareState(record: record))
    }

    var body: some View {
        VStack(spacing: 0) {
            DownloadPanelHeader(
                title: "分享下载二维码",
                subtitle: state.record.name,
                systemImage: "qrcode",
                tint: .accentColor
            ) { EmptyView() }
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
                         ? "扫码可在其他设备打开原始链接。链接中的临时签名也会随之分享。"
                         : "包含此任务保存的请求头和下载页面，可能含有 Cookie 或访问令牌。仅向可信设备分享。")
                        .font(.callout)
                        .foregroundStyle(state.mode == .source ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ZStack {
                        Color.white
                        if let image = state.image {
                            GeometryReader { geometry in
                                let moduleScale = max(1, floor(min(geometry.size.width, geometry.size.height) / CGFloat(image.dimensionInModules)))
                                let side = moduleScale * CGFloat(image.dimensionInModules)
                                Image(nsImage: NSImage(cgImage: image.cgImage, size: NSSize(width: image.cgImage.width, height: image.cgImage.height)))
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: side, height: side)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .accessibilityLabel("\(state.record.name) 的下载二维码")
                            }
                            .padding(12)
                        } else if state.isRendering {
                            ProgressView("正在生成二维码…")
                                .foregroundStyle(.black)
                        } else {
                            Image(systemName: "qrcode")
                                .font(.system(size: 64))
                                .foregroundStyle(.gray)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: DownloadVisualStyle.cornerRadius))

                    if let error = state.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(state.record.source.link)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack {
                        Button("复制图片", systemImage: "doc.on.doc") { state.copyImage() }
                            .disabled(state.image == nil)
                        Button("保存 PNG", systemImage: "square.and.arrow.down") { state.saveImage() }
                            .disabled(state.image == nil)
                        Button("复制来源文本", systemImage: "text.document") { state.copyText() }
                            .disabled(state.payload == nil)
                    }
                    if let notice = state.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            NativePageActionBar {
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .modifier(DownloadPanelSurface())
        .frame(minWidth: 560, idealWidth: 600, minHeight: 620, idealHeight: 680)
        .onDisappear { state.cancelRendering() }
    }
}

@MainActor
final class QRCodeShareState: ObservableObject {
    enum Mode: Hashable { case link, source }

    let record: DownloadRecord
    @Published var mode: Mode = .link
    @Published private(set) var image: QRCodeImage?
    @Published private(set) var payload: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var isRendering = false
    private var renderTask: Task<Void, Never>?
    private var generation = UUID()

    init(record: DownloadRecord) {
        self.record = record
        refresh()
    }

    func refresh() {
        renderTask?.cancel()
        let token = UUID()
        generation = token
        image = nil
        notice = nil
        errorMessage = nil
        do {
            let text: String
            switch mode {
            case .link: text = record.source.link
            case .source: text = try DownloadSourceShareCodec.encode([record.source])
            }
            payload = text
            isRendering = true
            renderTask = Task { [weak self] in
                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        return try QRCodeRenderer.render(text)
                    }
                    let result = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    guard let self, !Task.isCancelled, generation == token else { return }
                    image = result
                    isRendering = false
                } catch {
                    guard let self, !Task.isCancelled, generation == token else { return }
                    errorMessage = error.localizedDescription
                    isRendering = false
                }
            }
        } catch {
            payload = nil
            isRendering = false
            errorMessage = error.localizedDescription
        }
    }

    func cancelRendering() {
        generation = UUID()
        renderTask?.cancel()
        renderTask = nil
        isRendering = false
    }

    func copyText() {
        guard let payload else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(payload, forType: .string) else {
            errorMessage = "无法写入剪贴板，请重试。"
            return
        }
        notice = "已复制来源文本"
    }

    func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(image.pngData, forType: .png) else {
            errorMessage = "无法将图片写入剪贴板，请重试。"
            return
        }
        notice = "已复制二维码图片"
    }

    func saveImage() {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (record.name as NSString).deletingPathExtension + "-二维码.png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try image.pngData.write(to: url, options: .atomic)
                self?.notice = "二维码图片已保存"
            } catch {
                self?.errorMessage = "无法保存二维码图片：\(error.localizedDescription)"
            }
        }
    }
}
