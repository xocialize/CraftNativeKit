// CNCore — Rust's `Display` (`format!("{}", v)`, `v.to_string()`) for the values ported code formats,
// and `{:0NX}` hex. Ports core's float formatting behaviour (MIT OR Apache-2.0, © the Rust Project
// Developers); deckcraft-pptx (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors) writes
// every number in its XML parts this way, so parts are byte-identical only if this is.
//
// Floats: the shortest digits that read back to the same value, laid out in plain decimal with no
// exponent at any magnitude (`1e21` prints its 22 digits, `1e-7` prints `0.0000001`); no fraction when
// the value is integral (`1`, not `1.0`); `-0` for negative zero; `NaN` (never signed), `inf`, `-inf`.
//
// The digits are Swift's `description` digits with one correction. Both pick the shortest string in
// the rounding interval, and the closest to the exact value when several qualify; when two are exactly
// equally close, Swift takes the even one and core's Dragon4 (`format_shortest`: `2·mant >= scale`
// rounds up) takes the larger. So when the exact value is the midpoint `(D + ½)·10^k` of Swift's digits
// `D` and `D + 1` also reads back to the value, the digits are `D + 1`.

/// A value Rust code formats with `{}` / `ToString`. The XML builder (`A.a`) takes these.
public protocol RustDisplayable {
    /// `format!("{}", self)`.
    var rustDisplay: String { get }
}

extension Double: RustDisplayable {
    /// `format!("{}", self)` for an `f64`.
    public var rustDisplay: String {
        if isNaN { return "NaN" }
        if isInfinite { return self < 0 ? "-inf" : "inf" }
        let bits = bitPattern
        let expBits = Int((bits >> 52) & 0x7FF)
        let frac = bits & ((1 << 52) - 1)
        let (m, e) = expBits == 0 ? (frac, -1074) : (frac | (1 << 52), expBits - 1075)
        return RustFloatDisplay.plain(
            description: magnitude.description, negative: sign == .minus, mantissa: m, exponent2: e,
            readsBack: { Double($0) == magnitude }
        )
    }
}

extension Float: RustDisplayable {
    /// `format!("{}", self)` for an `f32`.
    public var rustDisplay: String {
        if isNaN { return "NaN" }
        if isInfinite { return self < 0 ? "-inf" : "inf" }
        let bits = bitPattern
        let expBits = Int((bits >> 23) & 0xFF)
        let frac = UInt64(bits & ((1 << 23) - 1))
        let (m, e) = expBits == 0 ? (frac, -149) : (frac | (1 << 23), expBits - 150)
        return RustFloatDisplay.plain(
            description: magnitude.description, negative: sign == .minus, mantissa: m, exponent2: e,
            readsBack: { Float($0) == magnitude }
        )
    }
}

extension RustDisplayable where Self: BinaryInteger {
    /// Integers print their decimal digits, `-` for negatives, as Swift's `String(_:)` does.
    public var rustDisplay: String { String(self) }
}

extension Int: RustDisplayable {}
extension Int8: RustDisplayable {}
extension Int16: RustDisplayable {}
extension Int32: RustDisplayable {}
extension Int64: RustDisplayable {}
extension UInt: RustDisplayable {}
extension UInt8: RustDisplayable {}
extension UInt16: RustDisplayable {}
extension UInt32: RustDisplayable {}
extension UInt64: RustDisplayable {}

extension String: RustDisplayable {
    public var rustDisplay: String { self }
}

extension Substring: RustDisplayable {
    public var rustDisplay: String { String(self) }
}

extension Bool: RustDisplayable {
    /// `true` / `false`.
    public var rustDisplay: String { self ? "true" : "false" }
}

extension Character: RustDisplayable {
    public var rustDisplay: String { String(self) }
}

/// The plain-decimal layout of core's `float_to_decimal_common_shortest` with no minimum precision.
enum RustFloatDisplay {
    /// `description` is Swift's shortest form of a finite non-negative value (`960.0`, `1e-05`), whose
    /// exact value is `mantissa · 2^exponent2`; `readsBack` says whether a decimal string parses back
    /// to that value.
    static func plain(
        description: String, negative: Bool, mantissa: UInt64, exponent2: Int, readsBack: (String) -> Bool
    ) -> String {
        let (shortest, k0) = ShortestFloat.decompose(description)
        var s = negative ? "-" : ""
        guard var digits = shortest else {
            s += "0"
            return s
        }
        var k = k0
        if isMidpoint(digits: digits, exponent10: k, mantissa: mantissa, exponent2: exponent2) {
            let up = incremented(digits)
            if readsBack(String(up) + "e" + String(k)) {
                digits = up
                while digits.count > 1, digits.last == "0" {
                    digits.removeLast()
                    k += 1
                }
            }
        }
        let length = digits.count
        let decExp = length + k - 1 // the power of ten of the first digit
        if k >= 0 {
            // 1234e3 -> 1234000
            s += String(digits) + String(repeating: "0", count: k)
        } else if decExp >= 0 {
            // 1234e-2 -> 12.34
            s += String(digits[...decExp]) + "." + String(digits[(decExp + 1)...])
        } else {
            // 1234e-6 -> 0.001234
            s += "0." + String(repeating: "0", count: -decExp - 1) + String(digits)
        }
        return s
    }
}

extension RustFloatDisplay {
    /// Is `mantissa · 2^exponent2` exactly `(digits + ½) · 10^exponent10`, that is
    /// `(10·digits + 5) · 10^(exponent10 − 1)`? Compared as odd part and power of two, in integers.
    static func isMidpoint(digits: [Character], exponent10: Int, mantissa: UInt64, exponent2: Int) -> Bool {
        guard mantissa != 0, digits.count <= 17 else { return false }
        var n: UInt64 = 0
        for c in digits {
            guard let v = c.wholeNumberValue else { return false }
            n = n * 10 + UInt64(v)
        }
        n = n * 10 + 5 // odd: the midpoint's significand
        let j = exponent10 - 1
        let shift = mantissa.trailingZeroBitCount
        let odd = mantissa >> UInt64(shift)
        let pow2 = exponent2 + shift
        // Multiply by 5 `count` times; nil on overflow (then the sides can't be equal).
        func times5(_ x: UInt64, _ count: Int) -> UInt64? {
            guard count <= 30 else { return nil }
            var x = x
            for _ in 0 ..< count {
                let (p, o) = x.multipliedReportingOverflow(by: 5)
                if o { return nil }
                x = p
            }
            return x
        }
        if j >= 0 {
            // odd · 2^pow2 = n · 5^j · 2^j
            guard pow2 == j, let rhs = times5(n, j) else { return false }
            return rhs == odd
        } else {
            // odd · 5^(−j) · 2^(pow2 − j) = n
            guard pow2 - j == 0, let lhs = times5(odd, -j) else { return false }
            return lhs == n
        }
    }

    /// `digits + 1` as a decimal string (`129` → `130`, `99` → `100`).
    static func incremented(_ digits: [Character]) -> [Character] {
        var d = digits
        var i = d.count - 1
        while i >= 0 {
            if d[i] == "9" {
                d[i] = "0"
                i -= 1
            } else {
                d[i] = Character(UnicodeScalar(UInt8(ascii: "0") + UInt8(d[i].wholeNumberValue ?? 0) + 1))
                return d
            }
        }
        return ["1"] + d
    }
}

/// Rust's `format!("{:0width$X}", v)` (or `x` when `uppercase` is false): hex digits, zero-padded to
/// at least `width`.
public func rustHex(_ v: some BinaryInteger, width: Int, uppercase: Bool = true) -> String {
    let digits = String(v, radix: 16, uppercase: uppercase)
    return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
}
