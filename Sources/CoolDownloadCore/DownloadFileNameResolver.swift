import Foundation

enum DownloadFileNameResolver {
    private static let contentDispositionQueryNames = [
        "response-content-disposition",
        "rscd"
    ]

    static func fromURL(_ link: String) -> String? {
        fromURLQuery(link) ?? pathOrHost(fromURL: link)
    }

    static func fromURLQuery(_ link: String) -> String? {
        guard let query = URLComponents(string: link)?.percentEncodedQuery else {
            return nil
        }

        var values: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = components.first else { continue }
            let name = decodeFormComponent(String(rawName)).lowercased()
            guard contentDispositionQueryNames.contains(name) else { continue }
            let rawValue = components.count > 1 ? String(components[1]) : ""
            values[name] = decodeFormComponent(rawValue)
        }

        for name in contentDispositionQueryNames {
            if let value = values[name], let fileName = fromContentDisposition(value) {
                return fileName
            }
        }
        return nil
    }

    static func pathOrHost(fromURL link: String) -> String? {
        guard let url = URL(string: link) else { return nil }
        if let pathName = sanitized(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) {
            return pathName
        }
        return sanitized(url.host ?? "")
    }

    static func fromContentDisposition(_ value: String?) -> String? {
        guard let value else { return nil }
        var regularName: String?
        var extendedName: String?

        let parameters = splitParameters(value)
        let firstParameterIsDisposition = parameters.first?.contains("=") != true
        for parameter in parameters.dropFirst(firstParameterIsDisposition ? 1 : 0) {
            let pieces = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = unquoted(String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines))
            switch key {
            case "filename*":
                extendedName = decodeExtendedValue(rawValue).flatMap(sanitized)
            case "filename":
                let decoded = rawValue.removingPercentEncoding ?? rawValue
                regularName = sanitized(decoded)
            default:
                continue
            }
        }
        return extendedName ?? regularName
    }

    static func sanitized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let scalars = trimmed.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            guard scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
            if scalar == "/" || scalar == "\\" {
                return "_"
            }
            return scalar
        }
        let result = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result != ".", result != ".." else { return nil }
        return result
    }

    static func isUUIDName(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func decodeFormComponent(_ value: String) -> String {
        let formDecoded = value.replacingOccurrences(of: "+", with: " ")
        return formDecoded.removingPercentEncoding ?? formDecoded
    }

    private static func splitParameters(_ value: String) -> [String] {
        var parameters: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\", isQuoted {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" {
                isQuoted.toggle()
                current.append(character)
                continue
            }
            if character == ";", !isQuoted {
                parameters.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parameters.append(current)
        return parameters
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return value
        }
        var result = ""
        var isEscaped = false
        for character in value.dropFirst().dropLast() {
            if isEscaped {
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        if isEscaped {
            result.append("\\")
        }
        return result
    }

    private static func decodeExtendedValue(_ value: String) -> String? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return value.removingPercentEncoding ?? value
        }
        let charset = parts[0].lowercased()
        guard let bytes = percentDecodedBytes(String(parts[2])) else { return nil }
        switch charset {
        case "utf-8", "utf8", "":
            return String(data: bytes, encoding: .utf8)
        case "iso-8859-1", "latin1", "iso-latin-1":
            return String(data: bytes, encoding: .isoLatin1)
        default:
            return String(data: bytes, encoding: .utf8)
        }
    }

    private static func percentDecodedBytes(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == Character("%").asciiValue {
                guard index + 2 < bytes.count,
                      let high = hexadecimalValue(bytes[index + 1]),
                      let low = hexadecimalValue(bytes[index + 2]) else {
                    return nil
                }
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
