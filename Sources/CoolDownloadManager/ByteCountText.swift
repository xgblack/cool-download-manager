import Foundation

enum ByteCountText {
    static func string(fromByteCount byteCount: Int64, formatter: ByteCountFormatter) -> String {
        let value = formatter.string(fromByteCount: byteCount)
        guard byteCount == 0 else { return value }
        guard let separator = value.firstIndex(where: \.isWhitespace) else { return "0" }
        return "0" + value[separator...]
    }
}
