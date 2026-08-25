import AppKit
import SwiftUI

/// Exposes the NSWindow created by SwiftUI's WindowGroup to the app coordinator.
@MainActor
struct WindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {
        nsView.onWindowChange = onWindowChange
        nsView.reportCurrentWindow()
    }
}

@MainActor
final class WindowTrackingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    private weak var lastReportedWindow: NSWindow?
    private var hasReportedWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportCurrentWindow()
    }

    func reportCurrentWindow() {
        // SwiftUI may attach the view before the NSWindow is fully connected.
        // Defer one turn so the coordinator receives the actual window instance.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let currentWindow = self.window
            guard !self.hasReportedWindow || currentWindow !== self.lastReportedWindow else { return }
            self.lastReportedWindow = currentWindow
            self.hasReportedWindow = true
            self.onWindowChange?(currentWindow)
        }
    }
}
