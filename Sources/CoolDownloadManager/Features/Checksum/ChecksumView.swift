import AppKit
import SwiftUI
import CoolDownloadCore

struct ChecksumView: View {
    let records: [DownloadRecord]
    let service: DownloadService?
    let onClose: () -> Void
    @StateObject private var state: ChecksumViewState

    init(records: [DownloadRecord], service: DownloadService?, onClose: @escaping () -> Void) {
        self.records = records
        self.service = service
        self.onClose = onClose
        _state = StateObject(wrappedValue: ChecksumViewState(records: records))
    }

    var body: some View {
        VStack(spacing: 0) {
            NativePageHeader(
                title: "验证文件完整性",
                subtitle: "已选中 \(records.count) 个任务",
                systemImage: "checkmark.shield",
                tint: .green
            ) {
                Picker("摘要算法", selection: $state.algorithm) {
                    ForEach(FileChecksumAlgorithm.allCases, id: \.self) { algorithm in
                        Text(algorithm.rawValue).tag(algorithm)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                Button {
                    start()
                } label: {
                    Label(state.isChecking ? "正在验证…" : "开始验证", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isChecking || records.isEmpty)
            }

            Divider()

            NativePageContent(maxWidth: 1_120, spacing: 0) {
                NativePageSurface(padding: 0) {
                    HStack(spacing: 10) {
                        Text("文件").frame(maxWidth: .infinity, alignment: .leading)
                        Text("状态").frame(width: 100, alignment: .leading)
                        Text("预期摘要（可选）").frame(width: 260, alignment: .leading)
                        Text("计算摘要").frame(width: 260, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.bar)
                    ForEach(records) { record in
                        row(record)
                        Divider()
                    }
                }
            }

            NativePageActionBar {
                if let message = state.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("关闭") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 900, idealWidth: 1_000, minHeight: 480, idealHeight: 580)
    }

    private func row(_ record: DownloadRecord) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name).lineLimit(1)
                Text(record.destinationURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(state.status(for: record.id))
                .font(.caption)
                .foregroundStyle(state.statusColor(for: record.id))
                .frame(width: 100, alignment: .leading)
            TextField("例如 SHA-256:十六进制值", text: state.expectedBinding(for: record.id))
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack(spacing: 4) {
                Text(state.calculated[record.id] ?? "-")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let calculated = state.calculated[record.id] {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(calculated, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制计算摘要")
                }
            }
            .frame(width: 260, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func start() {
        guard let service else {
            state.errorMessage = "下载核心尚未准备好"
            return
        }
        state.errorMessage = nil
        state.isChecking = true
        let calculator = FileChecksumCalculator()
        Task { @MainActor in
            defer { state.isChecking = false }
            for record in records {
                guard record.status == .completed else {
                    state.setStatus(record.id, "未完成", color: .orange)
                    continue
                }
                state.setStatus(record.id, "计算中", color: .accentColor)
                do {
                    let expectedText = state.expected[record.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let expected = expectedText.isEmpty ? nil : FileChecksum(string: expectedText)
                    if !expectedText.isEmpty, expected == nil {
                        throw ChecksumError.invalidExpectedChecksum
                    }
                    let algorithm = expected?.algorithm ?? state.algorithm
                    let calculated = try await Task.detached(priority: .userInitiated) {
                        try calculator.calculate(fileURL: record.destinationURL, algorithm: algorithm)
                    }.value
                    state.calculated[record.id] = calculated.description
                    if let expected {
                        state.setStatus(record.id, expected == calculated ? "匹配" : "不匹配", color: expected == calculated ? .green : .red)
                    } else {
                        state.setStatus(record.id, "已计算", color: .green)
                    }
                    let checksumToSave = expectedText.isEmpty ? nil : expected
                    try await service.updateChecksum(id: record.id, checksum: checksumToSave)
                } catch {
                    state.setStatus(record.id, error.localizedDescription, color: .red)
                }
            }
        }
    }
}

@MainActor
private final class ChecksumViewState: ObservableObject {
    @Published var algorithm: FileChecksumAlgorithm = .default
    @Published var expected: [DownloadID: String]
    @Published var calculated: [DownloadID: String] = [:]
    @Published var isChecking = false
    @Published var errorMessage: String?
    private var statuses: [DownloadID: (String, Color)] = [:]

    init(records: [DownloadRecord]) {
        expected = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.fileChecksum ?? "") })
        for record in records {
            statuses[record.id] = (record.status == .completed ? "等待" : "未完成", record.status == .completed ? .secondary : .orange)
        }
    }

    func expectedBinding(for id: DownloadID) -> Binding<String> {
        Binding(
            get: { self.expected[id] ?? "" },
            set: { self.expected[id] = $0 }
        )
    }

    func status(for id: DownloadID) -> String { statuses[id]?.0 ?? "等待" }
    func statusColor(for id: DownloadID) -> Color { statuses[id]?.1 ?? .secondary }

    func setStatus(_ id: DownloadID, _ status: String, color: Color) {
        statuses[id] = (status, color)
    }
}
