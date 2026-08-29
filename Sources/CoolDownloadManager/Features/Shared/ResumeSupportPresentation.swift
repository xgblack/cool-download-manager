import SwiftUI

enum ResumeSupportPresentation {
    static func text(_ supported: Bool?) -> String {
        switch supported {
        case true: return "是"
        case false: return "否"
        case nil: return "未知"
        }
    }

    static func systemImage(_ supported: Bool?) -> String {
        switch supported {
        case true: return "checkmark.circle.fill"
        case false: return "xmark.circle.fill"
        case nil: return "questionmark.circle"
        }
    }

    static func tint(_ supported: Bool?) -> Color {
        switch supported {
        case true: return .green
        case false: return .red
        case nil: return .secondary
        }
    }
}
