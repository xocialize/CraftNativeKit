// CNCore — Rust's string semantics where Swift's differ: Unicode-whitespace trimming, ASCII-only case
// mapping, and `format!("{v:.N}")`.
import Foundation

/// Rust's `str::trim`: strips Unicode `White_Space` scalars from both ends. Scalar by scalar, not character by
/// character: a space that a combining mark follows is still whitespace to Rust.
public func rustTrim(_ s: String) -> Substring {
    let u = s.unicodeScalars
    guard let start = u.firstIndex(where: { !$0.properties.isWhitespace }),
          let end = u.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
    return Substring(u[start ... end])
}

/// Rust's `to_ascii_lowercase`: only A–Z change.
public func rustASCIILowercase(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { ("A" ... "Z").contains($0) ? Unicode.Scalar($0.value + 32) ?? $0 : $0 }))
}

/// Rust's `format!("{v:.N}")`: fixed places, correctly rounded from the exact binary value, `-` kept on
/// a negative value that rounds to zero, `NaN` and `inf` spelled as Rust spells them.
public func rustFixed(_ v: Double, places: Int) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v < 0 ? "-inf" : "inf" }
    return String(format: "%.\(places)f", v)
}

/// Rust's `==` on strings: the same Unicode scalars (Swift's `==` also equates canonically equivalent
/// strings, such as precomposed and decomposed `é`).
public func rustEqual(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

/// Rust's `str::to_uppercase`: each scalar's full uppercase mapping, no context.
public func rustUppercase(_ s: String) -> String {
    s.unicodeScalars.map(\.properties.uppercaseMapping).joined()
}

/// Rust's `str::to_lowercase`: each scalar's full lowercase mapping, except that a capital sigma at the
/// end of a word becomes final sigma `ς` (preceded by a cased letter and not followed by one, skipping
/// case-ignorable characters), as Unicode's Final_Sigma condition says.
public func rustLowercase(_ s: String) -> String {
    let scalars = Array(s.unicodeScalars)
    var out = ""
    for (i, c) in scalars.enumerated() {
        if c == "\u{03A3}" {
            let before = scalars[..<i].reversed().first { !$0.properties.isCaseIgnorable }
            let after = scalars[(i + 1)...].first { !$0.properties.isCaseIgnorable }
            if before?.properties.isCased == true && after?.properties.isCased != true {
                out += "\u{03C2}"
                continue
            }
        }
        out += c.properties.lowercaseMapping
    }
    return out
}

/// Rust's `str::lines`: split on `\n`, dropping a `\r` before it and the empty piece after a final
/// newline.
public func rustLines(_ s: String) -> [String] {
    var lines = s.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { piece -> String in
        var v = String.UnicodeScalarView(piece)
        if v.last == "\r" { v.removeLast() }
        return String(v)
    }
    if s.unicodeScalars.last == "\n" || s.isEmpty { lines.removeLast() }
    return lines
}

/// Rust's `str::trim_start`, scalar by scalar.
public func rustTrimStart(_ s: Substring) -> Substring {
    let u = s.unicodeScalars
    guard let start = u.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
    return Substring(u[start...])
}

/// Rust's `str::trim_end`, scalar by scalar.
public func rustTrimEnd(_ s: Substring) -> Substring {
    let u = s.unicodeScalars
    guard let end = u.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
    return Substring(u[...end])
}

/// Rust's `str::parse::<f64>()`: an optional sign, then `inf`, `infinity` or `nan` (any case), or
/// digits with an optional `.` and fraction (at least one digit in all) and an optional exponent
/// (`e`/`E`, optional sign, at least one digit). Nothing else: no whitespace, hex, `_` or `nan(…)`,
/// which Swift's `Double(_:)` would accept. Correctly rounded; overflow gives ±infinity.
public func rustParseF64(_ s: some StringProtocol) -> Double? {
    guard rustFloatSyntax(s.utf8) else { return nil }
    return Double(String(s))
}

/// Rust's `str::parse::<f32>()`, with `rustParseF64`'s grammar.
public func rustParseF32(_ s: some StringProtocol) -> Float? {
    guard rustFloatSyntax(s.utf8) else { return nil }
    return Float(String(s))
}

/// Does `u` match core's float grammar (`dec2flt`)?
func rustFloatSyntax(_ u: some Collection<UInt8>) -> Bool {
    var b = Array(u)
    if let f = b.first, f == UInt8(ascii: "+") || f == UInt8(ascii: "-") { b.removeFirst() }
    if b.isEmpty { return false }
    let lower = String(decoding: b.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }, as: UTF8.self)
    if lower == "inf" || lower == "infinity" || lower == "nan" { return true }
    var i = 0
    func isDigit(_ x: UInt8) -> Bool { x >= 0x30 && x <= 0x39 }
    var digits = 0
    while i < b.count, isDigit(b[i]) { i += 1; digits += 1 }
    if i < b.count, b[i] == UInt8(ascii: ".") {
        i += 1
        while i < b.count, isDigit(b[i]) { i += 1; digits += 1 }
    }
    if digits == 0 { return false }
    if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
        i += 1
        if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
        var exp = 0
        while i < b.count, isDigit(b[i]) { i += 1; exp += 1 }
        if exp == 0 { return false }
    }
    return i == b.count
}
