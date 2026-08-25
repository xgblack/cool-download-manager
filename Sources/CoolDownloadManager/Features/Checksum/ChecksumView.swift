import SwiftUI
import CoolDownloadCore

struct ChecksumView: View {
    let records: [DownloadRecord]
    let service: DownloadService?
    let onClose: () -> Void
    @ObservedObject private var state: ChecksumViewState

    init(records: [DownloadRecord], service: DownloadService?, onClose: @escaping () -> Void) {
        self.records = records
        self.service = service
        self.onClose = onClose
        _state = ObservedObject(wrappedValue: ChecksumViewState(records: records))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("文件校验和", systemImage: "checkmark.shield")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(16)
            Divider()

            HStack {
                Picker("算法", selection: $state.algorithm) {
                    ForEach(FileChecksumAlgorithm.allCases, id: \.self) { algorithm in
                        Text(algorithm.rawValue).tag(algorithm)
                    }
                }
                .frame(width: 190)
                Text("已选中 \(records.count) 个任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    start()
                } label: {
                    Label(state.isChecking ? "校验中…" : "开始校验", systemImage: "play.fill")
                }
                .disabled(state.isChecking || records.isEmpty)
            }
            .padding(12)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("文件").frame(maxWidth: .infinity, alignment: .leading)
                        Text("状态").frame(width: 100, alignment: .leading)
                        Text("预期值（可选）").frame(width: 260, alignment: .leading)
                        Text("计算值").frame(width: 260, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.bar)
                    ForEach(records) { record in
                        row(record)
                        Divider()
                    }
                }
            }

            Divider()
            HStack {
                if let message = state.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 940, height: 540)
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
            TextField("ALGORITHM:hex", text: state.expectedBinding(for: record.id))
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
                    .help("复制校验值")
                }
            }
            .frame(width: 260, alignment: .leading)
        }
        .padding(12)
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
                state.setStatus(record.id, "校验中", color: .accentColor)
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
                        state.setStatus(record.id, "已完成", color: .green)
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
