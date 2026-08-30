import AppKit
import SwiftUI

/// The persisted theme is intentionally kept as a string for compatibility,
/// while the UI resolves unknown values to the system appearance.
enum AppTheme: Equatable {
    case system
    case light
    case dark

    init(_ rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dark":
            self = .dark
        case "light":
            self = .light
        default:
            self = .system
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// AppKit needs an explicit nil to release a previous per-window override.
    var windowAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

}

/// Conditional branches ensure switching from a fixed scheme to system mode
/// removes the old presentation preference instead of retaining a stale one.
struct AppThemeModifier: ViewModifier {
    let theme: AppTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch theme.preferredColorScheme {
        case .some(let colorScheme):
            content.preferredColorScheme(colorScheme)
        case .none:
            content
        }
    }
}

extension View {
    func appTheme(_ rawValue: String) -> some View {
        modifier(AppThemeModifier(theme: AppTheme(rawValue)))
    }
}
