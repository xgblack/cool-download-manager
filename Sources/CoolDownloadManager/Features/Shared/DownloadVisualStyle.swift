import SwiftUI
import CoolDownloadCore

/// Visual details shared by the download list and its two utility panels.
/// Window layout, system controls and Liquid Glass remain platform-owned.
enum DownloadVisualStyle {
    static let cornerRadius: CGFloat = 8
    static let hairline: CGFloat = 0.5
    static let formRowHeight: CGFloat = 44
    static let formInsets = EdgeInsets(top: 20, leading: 30, bottom: 20, trailing: 30)
    static let title = Font.headline.weight(.semibold)
    static let sectionTitle = Font.subheadline.weight(.semibold)
    static let metadata = Font.caption
    static let numeric = Font.callout.monospacedDigit()
    static let metric = Font.title3.weight(.medium).monospacedDigit()
    static let percentage = Font.system(size: 28, weight: .medium, design: .rounded).monospacedDigit()
    static let success = adaptiveColor(light: 0x24754A, dark: 0x63D995)
    static let warning = adaptiveColor(light: 0x986018, dark: 0xF3B866)
    static let failure = adaptiveColor(light: 0xB93237, dark: 0xFF827F)

    static func tint(for status: DownloadStatus) -> Color {
        switch status {
        case .completed: return success
        case .failed: return failure
        case .paused, .retrying, .waitingForSourceRefresh: return warning
        case .added, .cancelled: return .secondary
        case .preparing, .downloading: return .accentColor
        }
    }

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((hex >> 16) & 0xff) / 255,
                green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

struct DownloadIconTile: View {
    let systemImage: String
    let tint: Color
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(contrast == .increased ? 0.18 : 0.08), in: shape)
            .overlay {
                shape.strokeBorder(tint.opacity(contrast == .increased ? 0.5 : 0.12), lineWidth: DownloadVisualStyle.hairline)
            }
            .accessibilityHidden(true)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DownloadVisualStyle.cornerRadius, style: .continuous)
    }
}

struct DownloadPanelHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 11) {
            DownloadIconTile(systemImage: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DownloadVisualStyle.title)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(title)
                Text(subtitle)
                    .font(DownloadVisualStyle.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(minHeight: NativePageLayout.headerHeight)
    }
}

/// A continuous reading surface; only the window provides glass and depth.
struct DownloadPanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            Color(nsColor: .windowBackgroundColor)
                .opacity(reduceTransparency ? 1 : colorScheme == .dark ? 0.92 : 0.78)
                .ignoresSafeArea()
        }
    }
}

struct DownloadInputSurface: ViewModifier {
    let isFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .overlay {
                shape.strokeBorder(
                    isFocused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(contrast == .increased ? 1 : 0.6),
                    lineWidth: isFocused || contrast == .increased ? 1.5 : DownloadVisualStyle.hairline
                )
                .allowsHitTesting(false)
            }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DownloadVisualStyle.cornerRadius, style: .continuous)
    }
}

struct DownloadProgressTrack: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 5
    @Environment(\.colorSchemeContrast) private var contrast

    private var fraction: Double { value.isFinite ? min(1, max(0, value)) : 0 }

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.primary.opacity(contrast == .increased ? 0.2 : 0.07))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * fraction)
                }
                .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("下载进度")
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
    }
}
