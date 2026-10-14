import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoolDownloadCore

@MainActor
enum DownloadFileOpener {
    struct Application: Identifiable {
        let id: URL
        let name: String
        let isDefault: Bool
    }

    private static var applicationCache: [URL: (at: ContinuousClock.Instant, items: [Application])] = [:]

    static func applications(for url: URL) -> [Application] {
        // SwiftUI constructs native context menus without mounting their views.
        // Resolve synchronously; a short cache prevents progress refreshes from
        // repeatedly calling Launch Services for every completed row.
        if let cached = applicationCache[url], cached.at.duration(to: .now) < .seconds(5) { return cached.items }
        if applicationCache.count >= 128 { applicationCache.removeAll() }
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL
        let urls = Set(NSWorkspace.shared.urlsForApplications(toOpen: url).map(\.standardizedFileURL))
        var unique: [String: URL] = [:]
        for candidate in urls {
            let identifier = Bundle(url: candidate)?.bundleIdentifier ?? candidate.path
            let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.standardizedFileURL
            let current = unique[identifier]
            if current == nil || candidate == preferred
                || (current != preferred && candidate == registered)
                || (current != preferred && current != registered && candidate.path < current!.path) {
                unique[identifier] = candidate
            }
        }
        let result = unique.values.map { url in
            let display = FileManager.default.displayName(atPath: url.path)
            let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
            return Application(id: url, name: name, isDefault: url == preferred)
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.path < $1.id.path : order == .orderedAscending
        }
        applicationCache[url] = (.now, result)
        return result
    }

    static func validationError(for record: DownloadRecord) -> String? {
        guard record.status == .completed else { return "下载尚未完成，暂时无法打开文件。" }
        guard FileManager.default.fileExists(atPath: record.destinationURL.path) else {
            return "下载文件已被移动或删除，无法打开。"
        }
        return nil
    }

    static func open(_ record: DownloadRecord, application: URL? = nil, completion: @escaping @MainActor (String?) -> Void) {
        if let error = validationError(for: record) { completion(error); return }
        guard let application else {
            completion(NSWorkspace.shared.open(record.destinationURL) ? nil : "系统未能打开文件，请使用“打开方式”选择应用。")
            return
        }
        guard (try? application.resourceValues(forKeys: [.isApplicationKey]).isApplication) == true else {
            completion("所选应用不存在或不是有效的 macOS 应用。")
            return
        }
        NSWorkspace.shared.open([record.destinationURL], withApplicationAt: application, configuration: .init()) { _, error in
            let message = error.map { "无法使用所选应用打开文件：\($0.localizedDescription)" }
            Task { @MainActor in completion(message) }
        }
    }

    static func chooseApplication(for record: DownloadRecord, completion: @escaping @MainActor (String?) -> Void) {
        if let error = validationError(for: record) { completion(error); return }
        let panel = NSOpenPanel()
        panel.title = "选择打开文件的应用"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let app = panel.url else { return }
                open(record, application: app, completion: completion)
            }
        }
    }
}

struct OpenWithMenu: View {
    let record: DownloadRecord
    @ObservedObject var coordinator: AppCoordinator
    var onFailure: ((String) -> Void)?
    var onOpened: (() -> Void)?
    private var applications: [DownloadFileOpener.Application] {
        DownloadFileOpener.applications(for: record.destinationURL)
    }

    var body: some View {
        Menu("打开方式", systemImage: "app.badge") {
            if applications.isEmpty { Text("未找到关联应用") }
            ForEach(applications) { application in
                Button(application.name + (application.isDefault ? "（默认）" : "")) {
                    DownloadFileOpener.open(record, application: application.id, completion: report)
                }
                .help(application.id.path)
            }
            Divider()
            Button("其他应用…") {
                DownloadFileOpener.chooseApplication(for: record, completion: report)
            }
        }
        .disabled(record.status != .completed)

    }

    private func report(_ message: String?) {
        if let message {
            if let onFailure { onFailure(message) }
            else { coordinator.showNotice(message) }
        } else { onOpened?() }
    }
}
