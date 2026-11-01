@preconcurrency import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class QRCodeCameraController: ObservableObject {
    enum State: Equatable {
        case idle
        case requesting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private let capture = QRCodeCameraCapture()
    private var generation: UUID?
    private var authorizationTask: Task<Void, Never>?

    var session: AVCaptureSession { capture.session }

    func start(onTexts: @escaping @MainActor ([String]) -> Void) {
        stop()
        let token = UUID()
        generation = token
        state = .requesting
        authorizationTask = Task { [weak self] in
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let allowed: Bool
            switch status {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard let self, !Task.isCancelled, generation == token else { return }
            guard allowed else {
                state = .failed("未获得摄像头权限。可在系统设置中允许访问，或改为导入图片。")
                return
            }
            capture.start(onReady: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    switch result {
                    case .success: self.state = .running
                    case .failure(let message): self.state = .failed(message)
                    }
                }
            }, onTexts: { [weak self] texts in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.stop()
                    onTexts(texts)
                }
            })
        }
    }

    func stop() {
        generation = nil
        authorizationTask?.cancel()
        authorizationTask = nil
        capture.stop()
        state = .idle
    }

    deinit { capture.stop() }
}

private enum QRCodeCameraStartResult: Sendable {
    case success
    case failure(String)
}

/// AVFoundation session changes are confined to sessionQueue. Frame analysis
/// uses one serial queue and discards late frames; delivery is guarded by a
/// generation so stopping/restarting cannot return an old frame's result.
private final class QRCodeCameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.cooldownloadmanager.qr-camera.session")
    private let analysisQueue = DispatchQueue(label: "com.cooldownloadmanager.qr-camera.analysis", qos: .userInitiated)
    private let lock = NSLock()
    private struct Delivery {
        let token: UUID
        let callback: @Sendable ([String]) -> Void
        let status: @Sendable (QRCodeCameraStartResult) -> Void
        var output: AVCaptureVideoDataOutput?
    }
    private var delivery: Delivery?
    private var observers: [NSObjectProtocol] = []
    private var lastFrameTime: TimeInterval = 0

    override init() {
        super.init()
        for (name, message) in [
            (AVCaptureSession.runtimeErrorNotification, "摄像头发生错误，请重新打开摄像头或导入图片。"),
            (AVCaptureSession.wasInterruptedNotification, "摄像头扫描已中断，请重新打开摄像头或导入图片。")
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.failCurrentCapture(message)
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start(
        onReady: @escaping @Sendable (QRCodeCameraStartResult) -> Void,
        onTexts: @escaping @Sendable ([String]) -> Void
    ) {
        let token = UUID()
        lock.withLock { delivery = Delivery(token: token, callback: onTexts, status: onReady) }
        sessionQueue.async { [self] in
            guard lock.withLock({ delivery?.token == token }) else { return }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.sessionPreset = .high
            guard let device = AVCaptureDevice.default(for: .video) else {
                session.commitConfiguration()
                failCurrentCapture("没有可用的摄像头，请连接摄像头或导入图片。", token: token)
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: analysisQueue)
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    failCurrentCapture("无法打开摄像头，请确认设备可用并改用图片导入。", token: token)
                    return
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                guard lock.withLock({
                    guard delivery?.token == token else { return false }
                    delivery?.output = output
                    return true
                }) else { return }
                session.startRunning()
                guard lock.withLock({ delivery?.token == token }) else { return }
                guard session.isRunning else {
                    failCurrentCapture("摄像头未能启动，可能正被其他应用占用。可改为导入图片。", token: token)
                    return
                }
                onReady(.success)
            } catch {
                session.commitConfiguration()
                failCurrentCapture("摄像头无法访问，请检查权限与设备连接，或导入图片。", token: token)
            }
        }
    }

    func stop() {
        lock.withLock { delivery = nil }
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.outputs.forEach { session.removeOutput($0) }
            session.inputs.forEach { session.removeInput($0) }
            session.commitConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let token = lock.withLock({ delivery?.output === output ? delivery?.token : nil }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrameTime >= 0.25,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = now
        do {
            let texts = try QRCodeReader.read(pixelBuffer)
            guard !texts.isEmpty else { return }
            let callback = lock.withLock { () -> (@Sendable ([String]) -> Void)? in
                guard delivery?.token == token else { return nil }
                let callback = delivery?.callback
                delivery = nil
                return callback
            }
            guard let callback else { return }
            sessionQueue.async { [self] in if session.isRunning { session.stopRunning() } }
            callback(texts)
        } catch {
            failCurrentCapture("无法识别摄像头画面，请重新打开摄像头或导入图片。", token: token)
        }
    }

    private func failCurrentCapture(_ message: String, token: UUID? = nil) {
        let status = lock.withLock { () -> (@Sendable (QRCodeCameraStartResult) -> Void)? in
            guard let current = delivery, token == nil || current.token == token else { return nil }
            delivery = nil
            return current.status
        }
        guard let status else { return }
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
        status(.failure(message))
    }
}

struct QRCodeCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> QRCodeCameraPreviewView {
        let view = QRCodeCameraPreviewView()
        view.preview.session = session
        return view
    }

    func updateNSView(_ nsView: QRCodeCameraPreviewView, context: Context) {
        nsView.preview.session = session
    }
}

final class QRCodeCameraPreviewView: NSView {
    let preview = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }
}
