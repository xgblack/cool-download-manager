import AppKit
import SwiftUI

/// A quiet brand moment with useful version and support information.
struct AboutView: View {
    let checkForUpdates: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var versionCopied = false
    @State private var showsAcknowledgments = false

    fileprivate enum Layout {
        static let width: CGFloat = 600
        static let inset: CGFloat = 36
        static let accent = Color(red: 0.06, green: 0.47, blue: 0.50)
        static let blue = Color(red: 0.22, green: 0.50, blue: 0.84)

        static func secondary(in scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
            if contrast == .increased {
                return Color(white: scheme == .dark ? 0.82 : 0.30)
            }
            return Color(white: scheme == .dark ? 0.67 : 0.43)
        }
    }

    private let projectURL = URL(string: "https://github.com/xgblack/cool-download-manager")!
    private let issuesURL = URL(string: "https://github.com/xgblack/cool-download-manager/issues")!
    private let licenseURL = URL(string: "https://github.com/xgblack/cool-download-manager/blob/HEAD/LICENSE")!

    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.38, green: 0.79, blue: 0.78) : Layout.accent
    }

    private var secondary: Color {
        Layout.secondary(in: colorScheme, contrast: contrast)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
    }

    private var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private var versionDescription: String {
        if let build { return "版本 \(version)（构建 \(build)）" }
        return version
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity

            VStack(alignment: .leading, spacing: 26) {
                versionInformation
                Divider()
                projectLinks
                credits
            }
            .padding(Layout.inset)
        }
        .frame(width: Layout.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            versionCopied = false
            showsAcknowledgments = false
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("原生 macOS 下载管理器")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondary)

                Text("酷的下载管理器")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.7)
                    .accessibilityAddTraits(.isHeader)

                Text("让下载，井然有序。")
                    .font(.system(size: 16))
                    .foregroundStyle(secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.07), radius: 12, y: 6)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Layout.inset)
        .padding(.top, 64)
        .padding(.bottom, 42)
        .background {
            if !reduceTransparency && contrast != .increased {
                LinearGradient(
                    colors: [
                        Layout.accent.opacity(colorScheme == .dark ? 0.13 : 0.07),
                        Layout.blue.opacity(colorScheme == .dark ? 0.10 : 0.04),
                        .clear
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            }
        }
    }

    private var versionInformation: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(version)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        versionCopied = NSPasteboard.general.setString(
                            "酷的下载管理器 \(versionDescription)",
                            forType: .string
                        )
                    } label: {
                        Image(systemName: versionCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(versionCopied ? accent : Color.primary.opacity(0.65))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help(versionCopied ? "版本信息已复制" : "复制版本信息")
                    .accessibilityLabel(versionCopied ? "版本信息已复制" : "复制版本信息")
                }

                if let build {
                    Text("构建 \(build)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(secondary)
                }
            }

            Spacer()

            Button(action: checkForUpdates) {
                Label("检查更新", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var projectLinks: some View {
        HStack(alignment: .top, spacing: 28) {
            AboutProjectLink(
                "项目主页",
                subtitle: "源码、版本与最新进展",
                systemImage: "chevron.left.forwardslash.chevron.right",
                destination: projectURL
            )
            AboutProjectLink(
                "反馈问题",
                subtitle: "一起把下载体验做得更好",
                systemImage: "bubble.left.and.bubble.right",
                destination: issuesURL
            )
        }
    }

    private var credits: some View {
        HStack(spacing: 12) {
            Text("自由开源，持续打磨。")
                .foregroundStyle(secondary)
            Spacer(minLength: 8)
            Link("Apache 2.0", destination: licenseURL)
                .foregroundStyle(secondary)
            Button("开源致谢") {
                showsAcknowledgments.toggle()
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showsAcknowledgments, arrowEdge: .top) {
                acknowledgments
            }
        }
        .font(.system(size: 11))
        .tint(secondary)
        .padding(.top, 10)
    }

    private var acknowledgments: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("感谢开源同行")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 5) {
                Link("AB Download Manager ↗", destination: URL(string: "https://github.com/amir1376/ab-download-manager")!)
                Text("本项目的上游，启发了下载管理与浏览器集成。")
                    .foregroundStyle(secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Link("Sparkle ↗", destination: URL(string: "https://sparkle-project.org")!)
                Text("为 macOS 应用提供软件更新支持。")
                    .foregroundStyle(secondary)
            }
        }
        .font(.system(size: 12))
        .tint(accent)
        .padding(24)
        .frame(width: 370, alignment: .leading)
    }
}

/// Each link owns its hover state; feedback remains immediate with reduced motion.
private struct AboutProjectLink: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let destination: URL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    init(_ title: String, subtitle: String, systemImage: String, destination: URL) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.destination = destination
    }

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.38, green: 0.79, blue: 0.78)
            : AboutView.Layout.accent
    }

    var body: some View {
        Link(destination: destination) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                    Text(title)
                        .underline(isHovered)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? accent : .primary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AboutView.Layout.secondary(in: colorScheme, contrast: contrast))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("在浏览器中打开\(title)")
        .accessibilityLabel(title)
        .accessibilityHint("\(subtitle)，在浏览器中打开")
    }
}
