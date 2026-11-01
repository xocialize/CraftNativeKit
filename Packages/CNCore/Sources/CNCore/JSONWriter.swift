// CNCore — compact JSON output byte-identical to `serde_json::to_vec` (serde_json 1.0.154, zmij 1.0.23;
// both MIT OR Apache-2.0): the same string escapes, integers without a decimal point, and floats in
// zmij's shortest form (`960.0`, `0.00001`, `1e-7`, `1.5e+16`).

public struct JSONWriter: Sendable {
    /// Write NaN and ±infinity as `0.0` instead of `null`. deckcraft-format's `Finite` wrapper does this
    /// for saved files, because a `null` float doesn't read back.
    public var nonFiniteAsZero: Bool

    public init(nonFiniteAsZero: Bool = false) {
        self.nonFiniteAsZero = nonFiniteAsZero
    }

    public func bytes(_ value: JSON) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(1024)
        write(value, into: &out)
        return out
    }

    public func string(_ value: JSON) -> String {
        String(decoding: bytes(value), as: UTF8.self)
    }

    private func write(_ value: JSON, into out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let b):
            out.append(contentsOf: (b ? "true" : "false").utf8)
        case .uint(let v):
            out.append(contentsOf: String(v).utf8)
        case .int(let v):
            out.append(contentsOf: String(v).utf8)
        case .double(let v):
            if v.isFinite {
                out.append(contentsOf: ShortestFloat.format(v).utf8)
            } else {
                out.append(contentsOf: (nonFiniteAsZero ? "0.0" : "null").utf8)
            }
        case .float(let v):
            if v.isFinite {
                out.append(contentsOf: ShortestFloat.format(v).utf8)
            } else {
                out.append(contentsOf: (nonFiniteAsZero ? "0.0" : "null").utf8)
            }
        case .string(let s):
            JSONWriter.writeString(s, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                write(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            for (i, e) in o.entries.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                JSONWriter.writeString(e.key, into: &out)
                out.append(UInt8(ascii: ":"))
                write(e.value, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static let hex = Array("0123456789abcdef".utf8)

    /// serde_json's escapes: `"` and `\`, the five short control escapes, `\u00XX` (lowercase) for
    /// the other C0 controls; everything else, DEL and non-ASCII included, is written as UTF-8.
    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "\""): out.append(contentsOf: [0x5C, 0x22])
            case UInt8(ascii: "\\"): out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x00 ..< 0x20:
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"), hex[Int(b >> 4)], hex[Int(b & 0xF)]])
            default:
                out.append(b)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// zmij's `format_finite` layout (zmij 1.0.23, MIT OR Apache-2.0, which serde_json 1.0.154 prints floats
/// with) over Swift's shortest round-trip digits. Both print the shortest digit string that reads back
/// to the same value, choosing the closest when several tie, so the digits agree and only the layout
/// is ported: fixed notation while the first digit's power of ten is in `FIXED_DEC_EXP` (`960.0`,
/// `0.00001`), otherwise `1.5e+16`, `1e-7`.
public enum ShortestFloat {
    public static func format(_ v: Double) -> String {
        layout(description: v.magnitude.description, negative: v.sign == .minus, fixed: -5 ... 15)
    }

    public static func format(_ v: Float) -> String {
        layout(description: v.magnitude.description, negative: v.sign == .minus, fixed: -6 ... 12)
    }

    /// `description` is Swift's shortest form of a finite non-negative value: `960.0`, `0.001`,
    /// `1e-05`, `1.5e+20`.
    private static func layout(description: String, negative: Bool, fixed: ClosedRange<Int>) -> String {
        let (digits, k) = decompose(description)
        var s = negative ? "-" : ""
        guard let digits else {
            s += "0.0"
            return s
        }
        let length = digits.count
        let decExp = length + k - 1 // the power of ten of the first digit
        if fixed.contains(decExp) {
            if length - 1 <= decExp {
                // 1234e7 -> 12340000000.0
                s += String(digits) + String(repeating: "0", count: decExp + 1 - length) + ".0"
            } else if decExp >= 0 {
                // 1234e-2 -> 12.34
                s += String(digits[...decExp]) + "." + String(digits[(decExp + 1)...])
            } else {
                // 1234e-6 -> 0.001234
                s += "0." + String(repeating: "0", count: -decExp - 1) + String(digits)
            }
        } else {
            // 1234e30 -> 1.234e+33
            s += String(digits[0])
            if length > 1 { s += "." + String(digits[1...]) }
            s += (decExp >= 0 ? "e+" : "e-") + String(decExp.magnitude)
        }
        return s
    }

    /// The significant digits (no leading or trailing zeros) and the power of ten of the last one;
    /// nil digits for zero.
    static func decompose(_ description: String) -> (digits: [Character]?, exponent: Int) {
        var mantissa = Substring(description)
        var exponent = 0
        if let e = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = description[..<e]
            exponent = Int(description[description.index(after: e)...]) ?? 0
        }
        var digits: [Character] = []
        var afterPoint = 0
        var seenPoint = false
        for c in mantissa {
            if c == "." {
                seenPoint = true
            } else if c.isASCII, c.isNumber {
                digits.append(c)
                if seenPoint { afterPoint += 1 }
            }
        }
        var k = exponent - afterPoint
        while let first = digits.first, first == "0" { digits.removeFirst() }
        while let last = digits.last, last == "0" {
            digits.removeLast()
            k += 1
        }
        return (digits.isEmpty ? nil : digits, k)
    }
}
