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
    @Published private(set) var previewSources: [DownloadSource] = []
    @Published private(set) var previews: [Int: DownloadPreview] = [:]
    @Published private(set) var previewErrors: [Int: String] = [:]
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var previewValidationError: String?
    private var previewTask: Task<Void, Never>?
    private var previewTimeoutTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    var resolvedFolder: URL?
    var resolvedCategoryID: DownloadID?

    func matchingPreview(for source: DownloadSource) -> DownloadPreview? {
        previews.values.first { $0.source == source }
    }

    /// A bounded session owns its results. Cancellation never updates a newer draft.
    func loadPreviews(
        sources: [DownloadSource],
        debounce: Duration = .milliseconds(400),
        timeout: Duration = .seconds(15),
        operation: @escaping @Sendable (DownloadSource) async throws -> DownloadPreview
    ) {
        cancelPreviews()
        previewSources = sources
        previews = [:]
        previewErrors = [:]
        previewValidationError = nil
        guard !sources.isEmpty else { return }
        let generation = previewGeneration
        isLoadingPreview = true
        previewTask = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, self.previewGeneration == generation else { return }
            self.previewTimeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.previewGeneration == generation else { return }
                for index in sources.indices where self.previews[index] == nil && self.previewErrors[index] == nil {
                    self.previewErrors[index] = "文件信息加载超时，可重试或直接添加。"
                }
                self.cancelPreviews()
            }
            await withTaskGroup(of: (Int, DownloadPreview?, String?).self) { group in
                var next = 0
                func enqueue(_ index: Int) {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            return (index, try await operation(sources[index]), nil)
                        } catch {
                            return (index, nil, Self.previewErrorText(error))
                        }
                    }
                }
                for _ in 0..<min(2, sources.count) { enqueue(next); next += 1 }
                for await (index, preview, error) in group {
                    guard !Task.isCancelled, self.previewGeneration == generation else {
                        group.cancelAll()
                        return
                    }
                    self.previews[index] = preview
                    self.previewErrors[index] = error
                    if next < sources.count { enqueue(next); next += 1 }
                }
            }
            guard self.previewGeneration == generation else { return }
            self.isLoadingPreview = false
            self.previewTimeoutTask?.cancel()
            self.previewTimeoutTask = nil
        }
    }

    func invalidatePreviews(_ message: String?) {
        cancelPreviews()
        previewSources = []
        previews = [:]
        previewErrors = [:]
        previewValidationError = message
    }

    func cancelPreviews() {
        previewGeneration = UUID()
        previewTask?.cancel()
        previewTask = nil
        previewTimeoutTask?.cancel()
        previewTimeoutTask = nil
        isLoadingPreview = false
    }

    nonisolated private static func previewErrorText(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "文件信息加载超时，可重试或直接添加。"
            case .notConnectedToInternet: return "网络未连接，可稍后重试。"
            case .userAuthenticationRequired: return "服务器需要认证，可检查下载来源。"
            default: break
            }
        }
        // Network errors can contain signed URLs or request headers.
        return "暂时无法获取文件信息，可重试或按现有地址添加。"
    }

    func canRemember(folder: URL, defaultFolder: URL) -> Bool {
        folder.standardizedFileURL.path != defaultFolder.standardizedFileURL.path
    }
}
