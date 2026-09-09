import SwiftUI
import CoolDownloadCore
import CoolDownloadIntegration

/// State for a browser-triggered confirmation. It deliberately lives outside
/// MainViewState so the confirmation can outlive, and be shown without, the
/// download-list window.
@MainActor
final class BrowserDownloadConfirmationState: ObservableObject {
    let submission = DownloadSubmissionState()
    let initialDefaultFolder: URL
    let request: AddDownloadsRequest

    @Published var urlText: String
    @Published var nameText: String
    @Published var folderURL: URL
    @Published var queueID: DownloadID?
    @Published var categoryID: DownloadID?
    @Published var startImmediately: Bool

    init(request: AddDownloadsRequest, defaultFolder: URL) {
        self.initialDefaultFolder = defaultFolder
        self.request = request
        self.urlText = request.items.map(\.link).joined(separator: "\n")
        self.nameText = request.items.count == 1
            ? request.items[0].suggestedName ?? ""
            : ""
        self.folderURL = defaultFolder
        self.queueID = nil
        self.categoryID = nil
        self.startImmediately = true
    }
}

struct BrowserDownloadConfirmationView: View {
    @ObservedObject var state: BrowserDownloadConfirmationState
    let queues: [IntegrationQueue]
    let categories: [DownloadCategory]
    let onChooseFolder: () -> Void
    let onCancel: () -> Void
    let onAdd: (_ queueID: DownloadID?, _ categoryID: DownloadID?, _ startImmediately: Bool) -> Void

    var body: some View {
        AddDownloadSheet(
            urlText: $state.urlText,
            nameText: $state.nameText,
            folderURL: $state.folderURL,
            queueID: $state.queueID,
            categoryID: $state.categoryID,
            startImmediately: $state.startImmediately,
            submission: state.submission,
            defaultFolder: state.initialDefaultFolder,
            title: "确认下载",
            queues: queues,
            categories: categories,
            onChooseFolder: onChooseFolder,
            onCancel: onCancel,
            onAdd: onAdd
        )
    }
}
