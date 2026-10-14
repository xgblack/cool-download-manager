import AppKit
import CoreGraphics

/// Observes activity only while automatic limiting has active downloads.
@MainActor
final class ApplicationActivityMonitor: NSObject {
    struct Sample: Equatable {
        var isAppActive: Bool
        var isUserInteracting: Bool?
    }

    var onChange: ((Sample) -> Void)?
    private(set) var sample = Sample(isAppActive: NSApp?.isActive ?? false, isUserInteracting: true)
    private var pollingTask: Task<Void, Never>?
    private let idleTime: () -> TimeInterval

    init(idleTime: @escaping () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    }) {
        self.idleTime = idleTime
        super.init()
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(activityChanged), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activityChanged), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    deinit {
        pollingTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func setMonitoring(_ enabled: Bool) {
        guard enabled != (pollingTask != nil) else { return }
        if !enabled {
            pollingTask?.cancel()
            pollingTask = nil
            return
        }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        refresh()
    }

    @objc private func activityChanged() {
        guard pollingTask != nil else { return }
        refresh()
    }

    private func refresh() {
        let idle = idleTime()
        let next = Sample(
            isAppActive: NSApp?.isActive ?? false,
            isUserInteracting: idle.isFinite && idle >= 0 ? idle < 30 : nil
        )
        guard next != sample else { return }
        sample = next
        onChange?(next)
    }
}
