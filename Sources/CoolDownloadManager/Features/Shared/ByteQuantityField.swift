import Foundation
import SwiftUI

/// Unit conversion is shared by settings inputs and the menu-bar summary.
enum ByteQuantityText {
    static func multiplier(unit: String, exponent: Int) -> Decimal {
        let base = unit.hasPrefix("Binary") ? 1024 : 1000
        let value = (0..<exponent).reduce(Decimal(1)) { value, _ in value * Decimal(base) }
        return unit.hasSuffix("Bits") ? value / 8 : value
    }

    static func symbol(unit: String, exponent: Int, isSpeed: Bool) -> String {
        let binary = unit.hasPrefix("Binary")
        let prefixes = binary ? ["", "Ki", "Mi", "Gi"] : ["", "k", "M", "G"]
        let suffix = unit.hasSuffix("Bits") ? "bit" : "B"
        return prefixes[exponent] + suffix + (isSpeed ? "/s" : "")
    }

    static func format(bytes: Int64, unit: String, isSpeed: Bool) -> String {
        let exponent = (0...3).last { Decimal(bytes) >= multiplier(unit: unit, exponent: $0) } ?? 0
        let number = NSDecimalNumber(decimal: Decimal(bytes) / multiplier(unit: unit, exponent: exponent))
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return "\(formatter.string(from: number) ?? number.stringValue) \(symbol(unit: unit, exponent: exponent, isSpeed: isSpeed))"
    }

    static func parse(_ text: String, unit: String, exponent: Int, range: ClosedRange<Int64>) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil, let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let bytes = value * multiplier(unit: unit, exponent: exponent)
        guard !bytes.isNaN, bytes >= Decimal(range.lowerBound), bytes <= Decimal(range.upperBound) else { return nil }
        let integer = NSDecimalNumber(decimal: bytes).int64Value
        guard Decimal(integer) == bytes else { return nil }
        return integer
    }
}

struct ByteQuantityField: View {
    @Binding var bytes: Int64
    let unit: String
    let isSpeed: Bool
    let range: ClosedRange<Int64>
    let onValidation: (Bool) -> Void
    @State private var text = ""
    @State private var exponent = 0
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                TextField("数值", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .accessibilityLabel(isSpeed ? "全局限速上限" : "最小 Range 工作块大小")
                    .onChange(of: text) { _, _ in commit() }
                Picker("单位", selection: $exponent) {
                    ForEach(0...3, id: \.self) { value in
                        Text(ByteQuantityText.symbol(unit: unit, exponent: value, isSpeed: isSpeed)).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                .onChange(of: exponent) { _, _ in commit() }
            }
            if invalid {
                Text("请输入范围内的数值，换算后须为整数个字节")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { refresh() }
        .onChange(of: bytes) { _, _ in if !invalid { refresh(chooseUnit: false) } }
        .onChange(of: unit) { _, _ in refresh() }
    }

    private func refresh(chooseUnit: Bool = true) {
        if chooseUnit { exponent = (0...3).last { Decimal(bytes) >= ByteQuantityText.multiplier(unit: unit, exponent: $0) } ?? 0 }
        text = NSDecimalNumber(decimal: Decimal(bytes) / ByteQuantityText.multiplier(unit: unit, exponent: exponent)).stringValue
        invalid = false
        onValidation(true)
    }

    private func commit() {
        guard let value = ByteQuantityText.parse(text, unit: unit, exponent: exponent, range: range) else {
            invalid = true
            onValidation(false)
            return
        }
        invalid = false
        onValidation(true)
        if value != bytes { bytes = value }
    }
}
