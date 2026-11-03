import Foundation
import Testing
import CoolDownloadIntegration

@Suite("多帧二维码协议")
struct DownloadQRCodeTransferTests {
    @Test("保持上游的零起始帧序号及 CRC32 base36 标识")
    func upstreamWireFixture() throws {
        let frames = try DownloadQRCodeTransfer.frames(for: String(repeating: "a", count: 501))
        #expect(frames == ["<qr_m3g0/0/2>" + String(repeating: "a", count: 400), "<qr_m3g0/1/2>" + String(repeating: "a", count: 101)])
        var reader = DownloadQRCodeCollector()
        #expect(try reader.receive(frames[1]) == nil)
        #expect(reader.receivedIndices == [1])
        #expect(try reader.receive(frames[1]) == nil)
        #expect(reader.received == 1)
        #expect(try reader.receive(frames[0]) == String(repeating: "a", count: 501))
        #expect(reader.isComplete)
        #expect(try reader.receive(frames[0]) == nil)
    }

    @Test("短内容保留单码，Unicode 标量跨帧不被破坏")
    func unicodeAndSingleCode() throws {
        let short = "https://example.test/中文.zip"
        #expect(try DownloadQRCodeTransfer.frames(for: short) == [short])
        var reader = DownloadQRCodeCollector()
        #expect(try reader.receive(short) == short)
        let text = String(repeating: "下载🙂e\u{301}", count: 180)
        let frames = try DownloadQRCodeTransfer.frames(for: text)
        #expect(frames.count > 1)
        #expect(frames.allSatisfy { $0.utf8.count <= DownloadQRCodeTransfer.maximumFrameBytes })
        var assembled: String?
        for frame in frames.reversed() { assembled = try reader.receive(frame) ?? assembled }
        #expect(assembled?.utf8.elementsEqual(text.utf8) == true)
    }

    @Test("混入、总数变化及同序号冲突不会覆盖已收集的数据")
    func conflictsPreserveProgress() throws {
        var reader = DownloadQRCodeCollector()
        #expect(try reader.receive("<qr_test/0/2>first") == nil)
        for (text, error) in [
            ("<qr_other/1/2>second", DownloadQRCodeError.differentTransfer),
            ("https://example.test/other", .differentTransfer),
            ("<qr_test/1/3>second", .conflictingFrame),
            ("<qr_test/0/2>secret-conflict", .conflictingFrame)
        ] {
            #expect(throws: error) { _ = try reader.receive(text) }
            #expect(reader.total == 2 && reader.receivedIndices == [0])
        }
        #expect(try reader.receive("<qr_test/1/2>second") == "firstsecond")
        reader.reset()
        #expect(reader.total == 0 && reader.received == 0)
        #expect(try reader.receive("https://example.test/new") == "https://example.test/new")
    }

    @Test("非法帧及资源超限在分配收集空间前被拒绝", arguments: [
        "<qr_x/-1/2>secret", "<qr_x/2/2>secret", "<qr_x/0/0>secret", "<qr_x/0/257>secret",
        "<qr_x/0/99999999999999999999999999999999>secret", "<qr_x/0/2>", "<qr_X/0/2>secret", "<qr_x/0/2secret"
    ])
    func invalidFrames(text: String) {
        var reader = DownloadQRCodeCollector()
        #expect(throws: DownloadQRCodeError.invalidFrame) { _ = try reader.receive(text) }
        #expect(reader.total == 0 && reader.received == 0)
        #expect(!DownloadQRCodeError.invalidFrame.localizedDescription.contains("secret"))
    }

    @Test("发送容量、空内容和单帧容量都有明确边界")
    func capacityBounds() throws {
        #expect(throws: DownloadQRCodeError.empty) { _ = try DownloadQRCodeTransfer.frames(for: "") }
        #expect(try DownloadQRCodeTransfer.frames(for: String(repeating: "a", count: 400 * 256)).count == 256)
        #expect(throws: DownloadQRCodeError.tooLarge) { _ = try DownloadQRCodeTransfer.frames(for: String(repeating: "a", count: 400 * 256 + 1)) }
        var reader = DownloadQRCodeCollector()
        #expect(throws: DownloadQRCodeError.tooLarge) { _ = try reader.receive(String(repeating: "x", count: DownloadQRCodeTransfer.maximumPayloadBytes + 1)) }
        #expect(throws: DownloadQRCodeError.invalidFrame) { _ = try reader.receive("<qr_x/0/1>" + String(repeating: "x", count: 2331)) }
        #expect(reader.total == 0)
    }
}
