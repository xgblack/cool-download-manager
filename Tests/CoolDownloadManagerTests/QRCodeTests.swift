import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import CoolDownloadCore
import CoolDownloadIntegration
@testable import CoolDownloadManager

@Suite("下载二维码")
struct QRCodeTests {
    @Test("中文链接通过生成 PNG 与 Vision 原样往返")
    func unicodeLinkRoundTrip() throws {
        let text = "https://example.test/资料/下载.zip?文件名=中文&token=fixture-only"
        let image = try QRCodeRenderer.render(text)
        #expect(try QRCodeReader.read(image.pngData) == [text])
    }

    @Test("完整来源保留 HLS、请求头和下载页面")
    func sourceRoundTrip() throws {
        let source = DownloadSource(
            kind: .hls,
            link: "https://example.test/video/master.m3u8?签名=测试",
            headers: ["Cookie": "fixture=value", "User-Agent": "二维码测试"],
            downloadPage: "https://example.test/watch/1",
            suggestedName: "演示视频"
        )
        let payload = try DownloadSourceShareCodec.encode([source])
        let recognized = try #require(QRCodeReader.read(QRCodeRenderer.render(payload).pngData).first)
        #expect(try DownloadSourceShareCodec.decode(recognized) == [source])
    }

    @Test("相机像素缓冲能返回二维码内容和有效的识别框边界")
    func cameraPixelBufferObservations() throws {
        let text = "https://example.test/相机识别.zip"
        let image = try QRCodeRenderer.render(text).cgImage
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let observation = try #require(QRCodeReader.observations(buffer).first)
        #expect(observation.text == text)
        #expect(observation.bounds.width > 0 && observation.bounds.height > 0)
        #expect(observation.bounds.minX >= 0 && observation.bounds.maxX <= 1)
        #expect(observation.bounds.minY >= 0 && observation.bounds.maxY <= 1)
    }

    @Test("同一张图片中的多个二维码均可识别")
    func multipleCodes() throws {
        let first = "https://example.test/first.bin"
        let second = "https://example.test/second.bin"
        let left = try QRCodeRenderer.render(first, targetSize: 300)
        let right = try QRCodeRenderer.render(second, targetSize: 300)
        let context = try bitmap(width: 700, height: 360)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 700, height: 360))
        context.interpolationQuality = .none
        context.draw(left.cgImage, in: CGRect(x: 30, y: 40, width: left.cgImage.width, height: left.cgImage.height))
        context.draw(right.cgImage, in: CGRect(x: 370, y: 40, width: right.cgImage.width, height: right.cgImage.height))
        let image = try #require(context.makeImage())
        #expect(Set(try QRCodeReader.read(image)) == Set([first, second]))
    }

    @Test("生成图片使用纯黑白和完整白色留边")
    func blackAndWhiteQuietZone() throws {
        let image = try QRCodeRenderer.render("https://example.test/file.bin", targetSize: 512)
        let width = image.cgImage.width
        let height = image.cgImage.height
        #expect(width == height)
        #expect(width % image.dimensionInModules == 0)
        let quietZone = 4 * (width / image.dimensionInModules)
        let context = try bitmap(width: width, height: height)
        context.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var blackPixelCount = 0
        var isBlackAndWhite = true
        var isOpaque = true
        var hasWhiteBorder = true
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                let white = bytes[pixel] == 255 && bytes[pixel + 1] == 255 && bytes[pixel + 2] == 255
                let black = bytes[pixel] == 0 && bytes[pixel + 1] == 0 && bytes[pixel + 2] == 0
                isBlackAndWhite = isBlackAndWhite && (white || black)
                isOpaque = isOpaque && bytes[pixel + 3] == 255
                if black { blackPixelCount += 1 }
                if x < quietZone || y < quietZone || x >= width - quietZone || y >= height - quietZone {
                    hasWhiteBorder = hasWhiteBorder && white
                }
            }
        }
        #expect(blackPixelCount > 0)
        #expect(isBlackAndWhite)
        #expect(isOpaque)
        #expect(hasWhiteBorder)
    }

    @Test("空内容和 UTF-8 超容量不会生成截断二维码")
    func capacityErrors() {
        #expect(throws: QRCodeError.emptyContent) { try QRCodeRenderer.render("") }
        let text = String(repeating: "中", count: 778)
        #expect(text.utf8.count == 2334)
        #expect(throws: QRCodeError.contentTooLarge) { try QRCodeRenderer.render(text) }
    }

    @Test("无效图片、超大图片与没有二维码的图片分别报错")
    func recognitionErrors() throws {
        #expect(throws: QRCodeError.imageUnreadable) { try QRCodeReader.read(Data("not-an-image".utf8)) }
        #expect(throws: QRCodeError.imageTooLarge) {
            try QRCodeReader.read(Data(repeating: 0, count: QRCodeReader.maximumImageBytes + 1))
        }
        let context = try bitmap(width: 200, height: 200)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = try #require(context.makeImage())
        #expect(throws: QRCodeError.noCodeFound) { try QRCodeReader.read(png(image)) }
    }

    @Test("多码默认只选择第一个，合并选择时去重并保留请求信息")
    @MainActor
    func selectionPreservesSources() throws {
        let first = DownloadSource(kind: .http, link: "https://example.test/first", headers: ["Cookie": "fixture=value"])
        let second = DownloadSource(kind: .hls, link: "https://example.test/second.m3u8")
        let state = QRCodeImportState()
        let firstPayload = try DownloadSourceShareCodec.encode([first])
        let arrayPayload = try DownloadSourceShareCodec.encode([first, second])
        state.accept([firstPayload, arrayPayload, firstPayload])
        #expect(state.candidates.count == 2)
        #expect(state.selectedSources == [first])
        #expect(state.candidates[0].containsCredentials)
        state.selectedIDs = Set(state.candidates.map(\.id))
        #expect(state.selectedSources == [first, second])
        state.selectedIDs = []
        #expect(state.selectedSources.isEmpty)
    }

    @Test("非法来源不进入候选，部分成功和全部失败均有说明")
    @MainActor
    func invalidCandidates() {
        let state = QRCodeImportState()
        state.accept(["https://example.test/file.bin", "file:///etc/passwd"])
        #expect(state.candidates.count == 1)
        #expect(state.errorMessage != nil)
        state.accept(["invalid", "{broken-json}"])
        #expect(state.candidates.isEmpty)
        #expect(state.selectedSources.isEmpty)
        #expect(state.errorMessage != nil)
    }

    @Test("切换输入清除旧候选与选择")
    @MainActor
    func newInputClearsCandidates() {
        let state = QRCodeImportState()
        state.accept(["https://example.test/old.bin"])
        #expect(!state.selectedSources.isEmpty)
        state.importImage(data: Data())
        #expect(state.isReading)
        #expect(state.candidates.isEmpty)
        #expect(state.selectedSources.isEmpty)
        state.clear()
        #expect(!state.isReading)
        #expect(state.errorMessage == nil)
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
