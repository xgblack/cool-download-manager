import AppKit
import SwiftUI

/// Shared Liquid Glass primitives for the macOS client. Glass is reserved for
/// transient controls and utility panels; dense download content stays flat.
enum LiquidGlassMetrics {
    static let actionCornerRadius: CGFloat = 12
    static let panelCornerRadius: CGFloat = 20
}

struct LiquidGlassActionSurface<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if usesOpaqueFallback {
            layout
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay {
                    shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        } else {
            GlassEffectContainer(spacing: 10) {
                layout.glassEffect(
                    actionGlass,
                    in: shape
                )
            }
        }
    }

    private var layout: some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: NativePageLayout.actionBarHeight)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: LiquidGlassMetrics.actionCornerRadius,
            style: .continuous
        )
    }

    private var usesOpaqueFallback: Bool {
        reduceTransparency || colorSchemeContrast == .increased
    }

    private var actionGlass: Glass {
        // Keep the native glass untinted so the system remains responsible for
        // its appearance. The Appearance slider has no public numeric API.
        if #available(macOS 27.0, *) {
            return .regular.interactive()
        }
        return .regular
    }
}

/// Hosts utility-panel content in AppKit's native glass view. The explicit
/// fallback keeps panels readable when transparency is disabled system-wide.
@MainActor
final class LiquidGlassPanelViewController: NSViewController {
    private let hostingController: NSHostingController<AnyView>

    init<Content: View>(rootView: Content) {
        hostingController = NSHostingController(rootView: AnyView(rootView))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        addChild(hostingController)
        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false

        if shouldUseGlass {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.cornerRadius = LiquidGlassMetrics.panelCornerRadius
            // A nil tint leaves the global Liquid Glass appearance under
            // AppKit's control without depending on private defaults keys.
            glass.tintColor = nil
            glass.style = .regular
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            glass.contentView = hostedView
            container.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                glass.topAnchor.constraint(equalTo: container.topAnchor),
                glass.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        } else {
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            container.addSubview(hostedView)
            NSLayoutConstraint.activate([
                hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: container.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }

        view = container
    }

    private var shouldUseGlass: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}
