import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

enum QRCodeError: Error, LocalizedError, Equatable {
    case emptyContent
    case contentTooLarge
    case imageUnreadable
    case imageTooLarge
    case noCodeFound
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyContent: return "没有可分享的下载来源。"
        case .contentTooLarge: return "内容超过单个二维码的容量。请改为仅分享链接，或复制来源文本。"
        case .imageUnreadable: return "无法读取这张图片，请选择 PNG、JPEG、HEIC 等图片。"
        case .imageTooLarge: return "图片超过 32 MiB，请选择较小的图片。"
        case .noCodeFound: return "图片中没有识别到二维码，请使用更清晰、包含完整边缘的图片。"
        case .encodingFailed: return "无法生成二维码图片，请复制来源文本。"
        }
    }
}

struct QRCodeImage: @unchecked Sendable {
    // CGImage is immutable after construction. Rendering and recognition run
    // outside the main actor; AppKit receives only the finished image/data.
    let cgImage: CGImage
    let pngData: Data
    let dimensionInModules: Int
}

enum QRCodeRenderer {
    static func render(_ text: String, targetSize: Int = 512) throws -> QRCodeImage {
        let data = Data(text.utf8)
        guard !data.isEmpty else { throw QRCodeError.emptyContent }
        // QR version 40 at correction level M holds at most 2331 bytes in
        // byte mode. Check UTF-8 bytes, not the number of visible characters.
        guard data.count <= 2331 else { throw QRCodeError.contentTooLarge }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { throw QRCodeError.contentTooLarge }
        let dimension = Int(code.extent.width)
        let paddedDimension = dimension + 8
        let scale = max(1, targetSize / paddedDimension)
        let bounds = CGRect(x: 0, y: 0, width: paddedDimension, height: paddedDimension)
        let white = CIImage(color: .white).cropped(to: bounds)
        let padded = code.transformed(by: CGAffineTransform(translationX: 4, y: 4))
            .composited(over: white)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let image = context.createCGImage(padded, from: padded.extent) else {
            throw QRCodeError.encodingFailed
        }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw QRCodeError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw QRCodeError.encodingFailed }
        return QRCodeImage(cgImage: image, pngData: bytes as Data, dimensionInModules: paddedDimension)
    }
}

enum QRCodeReader {
    static let maximumImageBytes = 32 * 1024 * 1024

    static func read(_ data: Data) throws -> [String] {
        guard data.count <= maximumImageBytes else { throw QRCodeError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else {
            throw QRCodeError.imageUnreadable
        }
        let texts = try read(image)
        guard !texts.isEmpty else { throw QRCodeError.noCodeFound }
        return texts
    }

    static func read(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return uniquePayloads(request.results?.compactMap(\.payloadStringValue) ?? [])
    }

    static func read(_ pixelBuffer: CVPixelBuffer) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform([request])
        return uniquePayloads(request.results?.compactMap(\.payloadStringValue) ?? [])
    }

    private static func uniquePayloads(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
