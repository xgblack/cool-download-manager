import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@MainActor
@Suite("上游 1.11.2 列表与设置交互")
struct Upstream112PresentationTests {
    @Test("事件中的自动重试不会重新展示进度，主动恢复仍展示", arguments: [DownloadKind.http, .hls])
    func retryEventsKeepOnePresentation(kind: DownloadKind) {
        checkRetryPresentation(kind: kind, delivery: .events)
    }

    @Test("快照中的自动重试不会重新展示进度，主动恢复仍展示", arguments: [DownloadKind.http, .hls])
    func retrySnapshotsKeepOnePresentation(kind: DownloadKind) {
        checkRetryPresentation(kind: kind, delivery: .snapshots)
    }

    @Test("事件与快照交错或重复到达时重试仍只展示一次", arguments: [DownloadKind.http, .hls])
    func retryInterleavedUpdatesKeepOnePresentation(kind: DownloadKind) {
        checkRetryPresentation(kind: kind, delivery: .interleaved)
    }

    @Test("新任务的第一条准备事件会展示进度")
    func firstPreparingEventPresentsProgress() {
        let store = DownloadListStore(service: nil)
        let preparing = record(id: 8, status: .preparing)
        var starts: [DownloadID] = []
        store.onDownloadStarted = { starts.append($0.id) }
        store.apply(.created(preparing))
        store.apply(.updated(preparing))
        store.apply([preparing])
        #expect(starts == [8])
        #expect(store.progressID == 8)
    }

    @Test("保存位置按自然路径和名称排序，同名项顺序稳定且变更立即刷新")
    func locationSortIsStableAndRefreshes() {
        let store = DownloadListStore(service: nil)
        var laterFolder = record(id: 1, folder: "/tmp/folder10", name: "a.bin")
        var laterName = record(id: 2, folder: "/tmp/folder2", name: "file10.bin")
        let firstTie = record(id: 3, folder: "/tmp/folder2", name: "file2.bin")
        let secondTie = record(id: 4, folder: "/tmp/folder2", name: "file2.bin")
        let input = [laterFolder, secondTie, laterName, firstTie]
        store.apply(input, announceCompletion: false)
        store.sort = .location
        #expect(store.visibleDownloads.map(\.id) == [3, 4, 2, 1])

        store.apply(Array(input.reversed()), announceCompletion: false)
        #expect(store.visibleDownloads.map(\.id) == [3, 4, 2, 1])
        laterFolder.folder = "/tmp/folder1"
        laterFolder.revision += 1
        store.apply(.updated(laterFolder))
        #expect(store.visibleDownloads.map(\.id) == [1, 3, 4, 2])
        laterName.name = "file1.bin"
        laterName.revision += 1
        store.apply(.updated(laterName))
        #expect(store.visibleDownloads.map(\.id) == [1, 2, 3, 4])
    }

    @Test("即时列开关合并进未编辑字段，保留其他设置草稿且不制造未保存状态")
    func listPreferenceMergesWithoutOverwritingDraft() {
        var initial = AppSettingsModel.defaults()
        initial.showDownloadLocation = false
        let state = SettingsViewState(model: initial, perHostItems: [])
        state.model.theme = "dark"
        state.model.blockAddWhenLoading = !initial.blockAddWhenLoading
        var external = initial
        external.showDownloadLocation = true
        external.defaultDownloadFolder = "/tmp/external-folder"
        state.mergeListSettings(external)

        #expect(state.model.showDownloadLocation)
        #expect(state.model.theme == "dark")
        #expect(state.model.blockAddWhenLoading == !initial.blockAddWhenLoading)
        #expect(state.model.defaultDownloadFolder == initial.defaultDownloadFolder)
        #expect(state.isDirty)

        state.model.theme = initial.theme
        state.model.blockAddWhenLoading = initial.blockAddWhenLoading
        #expect(!state.isDirty)
        external.showDownloadLocation = false
        state.mergeListSettings(external)
        #expect(!state.model.showDownloadLocation)
        #expect(!state.isDirty)
    }

    @Test("设置页主动修改的列开关不被外部状态覆盖，后续仍以最新保存值合并")
    func explicitColumnDraftSurvivesExternalChanges() {
        var initial = AppSettingsModel.defaults()
        initial.showDownloadLocation = false
        let state = SettingsViewState(model: initial, perHostItems: [])
        state.model.showDownloadLocation = true
        state.mergeListSettings(initial)
        #expect(state.model.showDownloadLocation)
        #expect(state.isDirty)

        var external = initial
        external.showDownloadLocation = true
        state.mergeListSettings(external)
        #expect(state.model.showDownloadLocation)
        #expect(!state.isDirty)

        external.showDownloadLocation = false
        state.mergeListSettings(external)
        #expect(!state.model.showDownloadLocation)
        #expect(!state.isDirty)
    }

    private enum UpdateDelivery {
        case events, snapshots, interleaved
    }

    private func checkRetryPresentation(kind: DownloadKind, delivery: UpdateDelivery) {
        let store = DownloadListStore(service: nil)
        var current = record(id: 1, kind: kind)
        store.apply([current], announceCompletion: false)
        var starts: [DownloadStatus] = []
        store.onDownloadStarted = { starts.append($0.status) }
        var transitionIndex = 0

        func update(_ status: DownloadStatus) {
            current.status = status
            current.revision += 1
            current.updatedAt = current.updatedAt.addingTimeInterval(1)
            switch delivery {
            case .events:
                store.apply(.updated(current))
                store.apply(.updated(current))
            case .snapshots:
                store.apply([current])
                store.apply([current])
            case .interleaved:
                if transitionIndex.isMultiple(of: 2) {
                    store.apply(.updated(current))
                    store.apply([current])
                } else {
                    store.apply([current])
                    store.apply(.updated(current))
                }
            }
            transitionIndex += 1
        }

        update(.preparing)
        #expect(starts == [.preparing])
        #expect(store.progressID == current.id)
        store.acknowledgeProgress()
        for status: DownloadStatus in [.downloading, .retrying, .preparing, .downloading, .retrying, .downloading] {
            update(status)
            #expect(starts == [.preparing])
            #expect(store.progressID == nil)
        }

        update(.paused)
        update(.preparing)
        update(.downloading)
        #expect(starts == [.preparing, .preparing])
        #expect(store.progressID == current.id)
    }

    private func record(
        id: DownloadID,
        kind: DownloadKind = .http,
        folder: String = "/tmp/cooldm-presentation-test",
        name: String = "file.bin",
        status: DownloadStatus = .added
    ) -> DownloadRecord {
        DownloadRecord(
            id: id, source: DownloadSource(kind: kind, link: "https://fixture.invalid/file"),
            folder: folder, name: name, status: status,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
