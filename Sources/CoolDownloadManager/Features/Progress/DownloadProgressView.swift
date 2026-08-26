import SwiftUI
import CoolDownloadCore

/// Native macOS progress surface for one download.
///
/// The original client keeps the aggregate progress and the individual
/// connection parts visible together. `DownloadRecord.parts` is persisted by
/// the core, so the same information remains available after reopening the
/// panel or resuming a download.
struct DownloadProgressView: View {
    let record: DownloadRecord
    @ObservedObject var store: DownloadListStore
    @ObservedObject var coordinator: AppCoordinator
    let onClose: () -> Void

    @StateObject private var viewState = ProgressViewState()

    private var currentRecord: DownloadRecord {
        store.record(id: record.id) ?? record
    }

    private var currentSpeed: Double? {
        store.speed(
            for: currentRecord.id,
            average: coordinator.store.settings.useAverageSpeed
        )
    }

    private var progress: Double? {
        guard let total = currentRecord.totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(currentRecord.downloadedBytes) / Double(total)))
    }

    private var remainingText: String? {
        guard let total = currentRecord.totalBytes,
              let speed = currentSpeed,
              speed > 0,
              total > currentRecord.downloadedBytes else {
            return nil
        }
        return formattedDuration(Double(total - currentRecord.downloadedBytes) / speed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overview
                    partSection
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 660, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity)
        .onChange(of: currentRecord.status) { status in
            if status == .completed {
                onClose()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerIcon)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(headerColor)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(currentRecord.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            if let progress {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("总体进度")
                    .font(.headline)
                Spacer()
                Text(sizeText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(headerColor)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 20) {
                metric("速度", value: speedText)
                metric("剩余时间", value: remainingText ?? "--")
                metric("分片", value: "\(currentRecord.parts.count)")
                Spacer()
            }

            Text(currentRecord.source.link)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var partSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("分片进度")
                    .font(.headline)
                Spacer()
                if !currentRecord.parts.isEmpty {
                    Text("已完成 \(completedPartCount)/\(currentRecord.parts.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewState.showsPartDetails.toggle()
                    }
                } label: {
                    Label(
                        viewState.showsPartDetails ? "收起详情" : "展开详情",
                        systemImage: viewState.showsPartDetails ? "chevron.up" : "chevron.down"
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if currentRecord.parts.isEmpty {
                Text("等待服务器返回分片信息")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                partOverviewBar
                if viewState.showsPartDetails {
                    partTable
                }
            }
        }
    }

    private var partOverviewBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(sortedParts, id: \.id) { part in
                    let width = partLength(part)
                    PartProgressSegment(
                        part: part,
                        color: partColor(part),
                        width: max(3, proxy.size.width * width)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 12)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("各分片总体进度")
    }

    private var partTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("分片")
                    .frame(width: 50, alignment: .leading)
                Text("状态")
                    .frame(width: 90, alignment: .leading)
                Text("进度")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("已下载")
                    .frame(width: 100, alignment: .trailing)
                Text("范围")
                    .frame(width: 150, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            ForEach(sortedParts, id: \.id) { part in
                Divider()
                HStack(spacing: 12) {
                    Text("#\(part.id + 1)")
                        .frame(width: 50, alignment: .leading)
                    Label(partStatus(part), systemImage: partIcon(part))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(partColor(part))
                        .frame(width: 90, alignment: .leading)
                    ProgressView(value: partProgress(part))
                        .progressViewStyle(.linear)
                        .tint(partColor(part))
                        .frame(maxWidth: .infinity)
                    Text(partSizeText(part))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 100, alignment: .trailing)
                    Text(partRangeText(part))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 150, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
        }
        .font(.caption)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            switch currentRecord.status {
            case .preparing, .downloading, .retrying:
                Button("暂停", systemImage: "pause.fill") {
                    store.pause(id: currentRecord.id)
                }
            case .added, .paused:
                Button("继续", systemImage: "play.fill") {
                    store.start(id: currentRecord.id)
                }
            case .failed, .cancelled:
                Button("重试", systemImage: "arrow.clockwise") {
                    store.retry(id: currentRecord.id)
                }
            default:
                EmptyView()
            }

            Button("查看详情", systemImage: "info.circle") {
                onClose()
                coordinator.openDetail(for: currentRecord.id)
            }
            .disabled(store.record(id: currentRecord.id) == nil)

            Spacer()
            Button("关闭") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var sortedParts: [DownloadPart] {
        currentRecord.parts.sorted { $0.id < $1.id }
    }

    private var completedPartCount: Int {
        sortedParts.filter { part in
            part.completed || (partProgress(part) >= 1 && part.length != nil)
        }.count
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    private var sizeText: String {
        let downloaded = formattedByteCount(currentRecord.downloadedBytes)
        guard let total = currentRecord.totalBytes else { return downloaded }
        return "\(downloaded) / \(formattedByteCount(total))"
    }

    private var speedText: String {
        guard let currentSpeed, currentSpeed > 0 else { return "--" }
        return "\(speedFormatter.string(fromByteCount: Int64(currentSpeed))) / 秒"
    }

    private var statusText: String {
        switch currentRecord.status {
        case .added: return "已添加"
        case .preparing: return "准备中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .retrying: return "重试中"
        case .completed: return "已完成"
        case .failed: return currentRecord.error.map { "失败：\($0)" } ?? "失败"
        case .cancelled: return "已取消"
        }
    }

    private var headerIcon: String {
        switch currentRecord.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused, .cancelled: return "pause.circle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    private var headerColor: Color {
        switch currentRecord.status {
        case .completed: return .green
        case .failed: return .red
        case .paused, .cancelled: return .orange
        default: return .accentColor
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = coordinator.store.settings.sizeUnit == "DecimalBytes" ? .decimal : .binary
        return formatter
    }

    private var speedFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = coordinator.store.settings.speedUnit == "DecimalBytes" ? .decimal : .binary
        formatter.allowsNonnumericFormatting = false
        return formatter
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分钟"
        }
        if minutes > 0 {
            return "\(minutes) 分钟 \(remainingSeconds) 秒"
        }
        return "\(remainingSeconds) 秒"
    }

    private func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountText.string(fromByteCount: byteCount, formatter: byteFormatter)
    }

    private func partLength(_ part: DownloadPart) -> CGFloat {
        guard let to = part.to, to >= part.from else { return 1 / CGFloat(max(1, sortedParts.count)) }
        let length = max(1, to - part.from + 1)
        let total = sortedParts.reduce(Int64(0)) { result, item in
            guard let itemTo = item.to, itemTo >= item.from else { return result }
            return result + itemTo - item.from + 1
        }
        return total > 0 ? CGFloat(length) / CGFloat(total) : 1 / CGFloat(max(1, sortedParts.count))
    }

    private func partProgress(_ part: DownloadPart) -> Double {
        guard let to = part.to, to >= part.from else {
            return part.completed ? 1 : 0
        }
        let length = max(1, to - part.from + 1)
        return min(1, max(0, Double(part.downloaded) / Double(length)))
    }

    private func partStatus(_ part: DownloadPart) -> String {
        if part.completed || partProgress(part) >= 1 { return "已完成" }
        if currentRecord.status == .paused { return "已暂停" }
        if currentRecord.status == .failed || currentRecord.status == .cancelled { return "已停止" }
        if part.downloaded > 0 { return "下载中" }
        return "等待中"
    }

    private func partIcon(_ part: DownloadPart) -> String {
        if part.completed || partProgress(part) >= 1 { return "checkmark.circle.fill" }
        if part.downloaded > 0 { return "arrow.down.circle.fill" }
        return "circle"
    }

    private func partColor(_ part: DownloadPart) -> Color {
        if part.completed || partProgress(part) >= 1 { return .green }
        if currentRecord.status == .failed || currentRecord.status == .cancelled { return .red }
        if currentRecord.status == .paused { return .orange }
        if part.downloaded > 0 { return .accentColor }
        return .secondary.opacity(0.45)
    }

    private func partSizeText(_ part: DownloadPart) -> String {
        let downloaded = formattedByteCount(part.downloaded)
        guard let to = part.to, to >= part.from else { return downloaded }
        return "\(downloaded) / \(formattedByteCount(to - part.from + 1))"
    }

    private func partRangeText(_ part: DownloadPart) -> String {
        guard let to = part.to else { return "\(part.from)+" }
        return "\(part.from)-\(to)"
    }
}

@MainActor
private final class ProgressViewState: ObservableObject {
    @Published var showsPartDetails = true
}

private struct PartProgressSegment: View {
    let part: DownloadPart
    let color: Color
    let width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            color.opacity(0.18)
                .overlay(alignment: .leading) {
                    color
                        .frame(width: proxy.size.width * CGFloat(progress))
                }
        }
        .frame(width: width)
        .accessibilityLabel("分片 \(part.id + 1)，\(Int(progress * 100))%")
    }

    private var progress: Double {
        guard let to = part.to, to >= part.from else { return part.completed ? 1 : 0 }
        return min(1, max(0, Double(part.downloaded) / Double(to - part.from + 1)))
    }
}

private extension DownloadPart {
    var length: Int64? {
        guard let to, to >= from else { return nil }
        return to - from + 1
    }
}
