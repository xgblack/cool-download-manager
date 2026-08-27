import SwiftUI

/// Shared chrome for the app's secondary pages. The settings window is the
/// visual reference: compact material headers, restrained grouped surfaces,
/// and one stable action area at the bottom of an editor.
enum NativePageLayout {
    static let contentWidth: CGFloat = 780
    static let compactContentWidth: CGFloat = 680
    static let headerHeight: CGFloat = 58
    static let actionBarHeight: CGFloat = 60
    static let groupRadius: CGFloat = 8
}

struct NativePageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: NativePageLayout.headerHeight)
        .background(.bar)
    }
}

extension NativePageHeader where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = .accentColor
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            tint: tint
        ) {
            EmptyView()
        }
    }
}

struct NativePageContent<Content: View>: View {
    let maxWidth: CGFloat
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        maxWidth: CGFloat = NativePageLayout.contentWidth,
        spacing: CGFloat = 24,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.maxWidth = maxWidth
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .frame(maxWidth: maxWidth, alignment: .topLeading)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct NativePageSurface<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        padding: CGFloat = 16,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: NativePageLayout.groupRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativePageLayout.groupRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 0.5)
        }
    }
}

struct NativePageActionBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .frame(minHeight: NativePageLayout.actionBarHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct NativeSidebarHeader: View {
    let title: String
    let count: Int
    let systemImage: String
    let tint: Color

    init(title: String, count: Int, systemImage: String, tint: Color = .accentColor) {
        self.title = title
        self.count = count
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }
}

struct NativeEmptyState<Action: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder let action: () -> Action

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

extension NativeEmptyState where Action == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) {
            EmptyView()
        }
    }
}
