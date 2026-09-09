import Foundation
import SwiftUI
import CoolDownloadCore

/// One confirmation owns its options and successful IDs, including across retries.
@MainActor
final class DownloadSubmissionState: ObservableObject {
    @Published var rememberFolder = false
    @Published var folderWasChosen = false
    @Published var isSubmitting = false
    @Published var errorMessage: String?
    @Published var addedIDs: [DownloadID] = []
    @Published var tasksAdded = false
    var resolvedFolder: URL?
    var resolvedCategoryID: DownloadID?

    func canRemember(folder: URL, defaultFolder: URL) -> Bool {
        folder.standardizedFileURL.path != defaultFolder.standardizedFileURL.path
    }
}
