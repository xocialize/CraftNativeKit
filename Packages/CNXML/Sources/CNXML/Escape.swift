// CNXML — escaping, unescaping and normalisation: a port of quick-xml 0.41.0's src/escape.rs (MIT, © Johann Tuffe
// and the quick-xml contributors), without the `escape-html` feature. Everything works on UTF-8 bytes; offsets in
// errors are byte offsets, as Rust's are.

/// The XML version a text or attribute is normalised for (`quick_xml::XmlVersion`).
public enum XMLVersion: Sendable, Equatable {
    /// No declaration: 1.0 is assumed.
    case implicit1_0
    case explicit1_0
    case explicit1_1
}

public enum XMLEscape {
    /// `escape`: `<`, `>`, `&`, `'` and `"` as entities.
    public static func escape(_ raw: String) -> String {
        escape(raw) { $0 == 0x3C || $0 == 0x3E || $0 == 0x26 || $0 == 0x27 || $0 == 0x22 }
    }

    /// `partial_escape`: `<`, `>` and `&`.
    public static func partialEscape(_ raw: String) -> String {
        escape(raw) { $0 == 0x3C || $0 == 0x3E || $0 == 0x26 }
    }

    /// `minimal_escape`: `<` and `&`.
    public static func minimalEscape(_ raw: String) -> String {
        escape(raw) { $0 == 0x3C || $0 == 0x26 }
    }

    static func escape(_ raw: String, _ needs: (UInt8) -> Bool) -> String {
        guard raw.utf8.contains(where: needs) else { return raw }
        var out: [UInt8] = []
        out.reserveCapacity(raw.utf8.count + 8)
        for b in raw.utf8 {
            guard needs(b) else {
                out.append(b)
                continue
            }
            switch b {
            case 0x3C: out.append(contentsOf: "&lt;".utf8)
            case 0x3E: out.append(contentsOf: "&gt;".utf8)
            case 0x27: out.append(contentsOf: "&apos;".utf8)
            case 0x26: out.append(contentsOf: "&amp;".utf8)
            case 0x22: out.append(contentsOf: "&quot;".utf8)
            case 0x09: out.append(contentsOf: "&#9;".utf8)
            case 0x0A: out.append(contentsOf: "&#10;".utf8)
            case 0x0D: out.append(contentsOf: "&#13;".utf8)
            case 0x20: out.append(contentsOf: "&#32;".utf8)
            default: out.append(b)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `resolve_xml_entity`: the five predefined entities.
    public static func resolveXMLEntity(_ name: some Collection<UInt8>) -> String? {
        if name.elementsEqual("lt".utf8) { return "<" }
        if name.elementsEqual("gt".utf8) { return ">" }
        if name.elementsEqual("amp".utf8) { return "&" }
        if name.elementsEqual("apos".utf8) { return "'" }
        if name.elementsEqual("quot".utf8) { return "\"" }
        return nil
    }

    /// `unescape`: entity and character references resolved, with the predefined entities.
    public static func unescape(_ raw: String) throws(XMLEscapeError) -> String {
        let b = Array(raw.utf8)
        guard b.contains(0x26) else { return raw }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var lastEnd = 0
        var i = 0
        // memchr2_iter over `&` and `;`: find an `&`, then the very next `&` or `;` must be a `;`.
        while i < b.count {
            guard b[i] == 0x26 else { // never-crash: i < b.count
                i += 1
                continue
            }
            let start = i
            var j = i + 1
            while j < b.count, b[j] != 0x26, b[j] != 0x3B { j += 1 } // never-crash: j < b.count
            guard j < b.count, b[j] == 0x3B else { throw .unterminatedEntity(start ..< b.count) } // never-crash: j < b.count
            out.append(contentsOf: b[lastEnd ..< start]) // never-crash: lastEnd <= start <= count
            let pat = b[(start + 1) ..< j] // never-crash: start < j
            if pat.first == 0x23 {
                let c = try parseNumberOrEscape(pat.dropFirst())
                out.append(contentsOf: String(Character(c)).utf8)
            } else if let v = resolveXMLEntity(pat) {
                out.append(contentsOf: v.utf8)
            } else {
                throw .unrecognizedEntity((start + 1) ..< j, String(decoding: pat, as: UTF8.self))
            }
            lastEnd = j + 1
            i = j + 1
        }
        out.append(contentsOf: b[lastEnd...]) // never-crash: lastEnd <= count
        return String(decoding: out, as: UTF8.self)
    }

    static func parseNumberOrEscape(_ num: ArraySlice<UInt8>) throws(XMLEscapeError) -> Unicode.Scalar {
        do {
            return try parseNumber(num)
        } catch {
            throw .invalidCharRef(error)
        }
    }

    /// `parse_number`: the text after `&#` (`x` and hex digits, or decimal digits) as a character. No sign, not 0,
    /// not a surrogate, not beyond U+10FFFF.
    public static func parseNumber(_ num: some Collection<UInt8>) throws(XMLCharRefError) -> Unicode.Scalar {
        var digits = Array(num)[...]
        var radix: UInt32 = 10
        if digits.first == 0x78 { // `x`
            digits = digits.dropFirst()
            radix = 16
        }
        let code = try fromStrRadix(digits, radix)
        if code == 0 { throw .illegalCharacter(code) }
        guard let c = Unicode.Scalar(code) else { throw .invalidCodepoint(code) }
        return c
    }

    /// quick-xml's `from_str_radix`: a sign is an error of its own, then `u32::from_str_radix`.
    static func fromStrRadix(_ src: ArraySlice<UInt8>, _ radix: UInt32) throws(XMLCharRefError) -> UInt32 {
        if let f = src.first, f == 0x2B || f == 0x2D { throw .unexpectedSign }
        guard !src.isEmpty else { throw .invalidNumber(.empty) }
        var result: UInt32 = 0
        for c in src {
            // Rust's checked loop: the multiplication is computed first, the digit checked, then the overflows.
            let (mul, o1) = result.multipliedReportingOverflow(by: radix)
            let x: UInt32
            switch c {
            case 0x30 ... 0x39: x = UInt32(c - 0x30)
            case 0x61 ... 0x66 where radix == 16: x = UInt32(c - 0x61 + 10)
            case 0x41 ... 0x46 where radix == 16: x = UInt32(c - 0x41 + 10)
            default: throw .invalidNumber(.invalidDigit)
            }
            if o1 { throw .invalidNumber(.posOverflow) }
            let (sum, o2) = mul.addingReportingOverflow(x)
            if o2 { throw .invalidNumber(.posOverflow) }
            result = sum
        }
        return result
    }

    // MARK: - End-of-line normalisation

    /// `normalize_xml10_eols`: CR LF and a lone CR become LF.
    public static func normalizeXML10EOLs(_ text: String) -> String {
        // Over contiguous bytes where they are: the iterator's byte loop was a fiftieth of an XLSX read.
        let hasCR = text.utf8.withContiguousStorageIfAvailable { $0.contains(0x0D) } ?? text.utf8.contains(0x0D)
        guard hasCR else { return text }
        let b = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let x = b[i] // never-crash: i < b.count
            if x == 0x0D {
                out.append(0x0A)
                i += (i + 1 < b.count && b[i + 1] == 0x0A) ? 2 : 1 // never-crash: checked
            } else {
                out.append(x)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `normalize_xml11_eols`: also NEL (U+0085), CR NEL and LINE SEPARATOR (U+2028).
    public static func normalizeXML11EOLs(_ text: String) -> String {
        let b = Array(text.utf8)
        guard b.contains(where: { $0 == 0x0D || $0 == 0xC2 || $0 == 0xE2 }) else { return text }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var pos = 0
        while pos < b.count {
            guard let i = b[pos...].firstIndex(where: { $0 == 0x0D || $0 == 0xC2 || $0 == 0xE2 }) else { break }
            out.append(contentsOf: b[pos ..< i]) // never-crash: pos <= i
            pos = xml11EOLStep(&out, b, i, 0x0A)
        }
        if pos < b.count { out.append(contentsOf: b[pos...]) } // never-crash: checked
        return String(decoding: out, as: UTF8.self)
    }

    /// `normalize_xml10_eol_step`: the byte at `index` is CR or LF; appends `ch` and returns where to go on.
    static func xml10EOLStep(_ out: inout [UInt8], _ input: [UInt8], _ index: Int, _ ch: UInt8) -> Int {
        out.append(ch)
        if input[index] == 0x0D, index + 1 < input.count, input[index + 1] == 0x0A { return index + 2 } // never-crash: index from a search
        return index + 1
    }

    /// `normalize_xml11_eol_step`: the byte at `index` is CR, LF, 0xC2 or 0xE2 (the input is valid UTF-8).
    static func xml11EOLStep(_ out: inout [UInt8], _ input: [UInt8], _ index: Int, _ ch: UInt8) -> Int {
        let n = input.count
        func slice(_ a: Int, _ b: Int) -> ArraySlice<UInt8> { input[Swift.min(a, n) ..< Swift.min(b, n)] } // never-crash: clamped
        switch input[index] { // never-crash: index from a search
        case 0x0D:
            if index + 1 < n {
                let next = input[index + 1] // never-crash: checked
                if next == 0x0A {
                    out.append(ch)
                    return index + 2
                }
                if next == 0xC2 {
                    if index + 2 < n, input[index + 2] == 0x85 { // never-crash: checked
                        out.append(ch)
                    } else {
                        out.append(ch)
                        out.append(contentsOf: slice(index + 1, index + 3))
                    }
                    return index + 3
                }
            }
            out.append(ch)
            return index + 1
        case 0x0A:
            out.append(ch)
            return index + 1
        case 0xC2:
            if index + 1 < n, input[index + 1] == 0x85 { // never-crash: checked
                out.append(ch)
            } else {
                out.append(contentsOf: slice(index, index + 2))
            }
            return index + 2
        default: // 0xE2
            if index + 2 < n, input[index + 1] == 0x80, input[index + 2] == 0xA8 { // never-crash: checked
                out.append(ch)
            } else {
                out.append(contentsOf: slice(index, index + 3))
            }
            return index + 3
        }
    }

    // MARK: - Attribute values

    /// `normalize_xml10_attribute_value` / `normalize_xml11_attribute_value` with `resolve_predefined_entity`
    /// (XML 1.0 §3.3.3): references resolved, each whitespace character a space, line ends one space.
    public static func normalizeAttributeValue(_ value: String, version: XMLVersion, depth: Int = 1) throws(XMLEscapeError) -> String {
        let xml11 = version == .explicit1_1
        // Checked in place: most values need nothing, and copying each one first cost a tenth of an XLSX read.
        let needs = value.utf8.withContiguousStorageIfAvailable { $0.contains { isNormalizationChar($0, xml11) } }
            ?? value.utf8.contains(where: { isNormalizationChar($0, xml11) })
        guard needs else { return value }
        let input = Array(value.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        try normalizeAttrSteps(&out, input, depth: depth, xml11: xml11)
        return String(decoding: out, as: UTF8.self)
    }

    @inline(__always)
    static func isNormalizationChar(_ b: UInt8, _ xml11: Bool) -> Bool {
        b == 0x09 || b == 0x0D || b == 0x0A || b == 0x26 || (xml11 && (b == 0xC2 || b == 0xE2))
    }

    /// `normalize_attr_steps` over all of `input`, from its start.
    static func normalizeAttrSteps(_ out: inout [UInt8], _ input: [UInt8], depth: Int, xml11: Bool) throws(XMLEscapeError) {
        var pos = 0
        // `iter` in Rust: the next byte position not yet looked at.
        var it = 0
        while true {
            var found: Int?
            while it < input.count {
                let b = input[it] // never-crash: it < count
                it += 1
                if isNormalizationChar(b, xml11) {
                    found = it - 1
                    break
                }
            }
            guard let index = found else { break }
            pos = try normalizeAttrStep(&out, &it, input, lastPos: pos, index: index, depth: depth, xml11: xml11)
        }
        if pos < input.count { out.append(contentsOf: input[pos...]) } // never-crash: checked
    }

    /// `normalize_attr_step`: `input[index]` is a normalisation character; `it` is just after it.
    static func normalizeAttrStep(_ out: inout [UInt8], _ it: inout Int, _ input: [UInt8], lastPos: Int, index: Int,
                                  depth: Int, xml11: Bool) throws(XMLEscapeError) -> Int {
        if depth == 0 { throw .tooManyNestedEntities }
        out.append(contentsOf: input[lastPos ..< index]) // never-crash: lastPos <= index
        switch input[index] { // never-crash: index < count
        case 0x26:
            let start = index + 1
            var end = it
            while end < input.count, input[end] != 0x3B { end += 1 } // never-crash: end < count
            guard end < input.count else { throw .unterminatedEntity(index ..< input.count) }
            it = end + 1
            let pat = input[start ..< end] // never-crash: start <= end
            if pat.first == 0x23 {
                let c = try parseNumberOrEscape(pat.dropFirst())
                out.append(contentsOf: String(Character(c)).utf8)
            } else if pat.elementsEqual("amp".utf8) {
                out.append(0x26)
            } else if let v = resolveXMLEntity(pat) {
                try normalizeAttrSteps(&out, Array(v.utf8), depth: Swift.max(depth - 1, 0), xml11: xml11)
            } else {
                throw .unrecognizedEntity(start ..< end, String(decoding: pat, as: UTF8.self))
            }
            return end + 1
        case 0x09:
            out.append(0x20)
            return index + 1
        default:
            let pos = xml11 ? xml11EOLStep(&out, input, index, 0x20) : xml10EOLStep(&out, input, index, 0x20)
            it = Swift.max(it, Swift.min(pos, input.count))
            return pos
        }
    }
}
