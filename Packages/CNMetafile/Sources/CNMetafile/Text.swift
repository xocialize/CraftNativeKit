// CNMetafile — text records: the font (LOGFONT), the text string decoded from its character set, and the
// neutral `MetafileText` item. The metafile reader knows no fonts, so measuring, alignment against the font's
// metrics and glyph drawing are left to the renderer. Port of deckcraft crates/metafile/src/text.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).

/// A font chosen by a CREATEFONTINDIRECT record (MS-WMF 2.2.1.2 Font, MS-EMF 2.2.13 LogFont).
public struct MetafileFont: Equatable, Sendable {
    /// The face name the file asks for (`"Arial"`, `"Wingdings"`); may be empty.
    public var family: String = ""
    /// LOGFONT height in text units: negative is the character (em) height, positive the cell height (ascent
    /// plus descent), 0 the default size.
    public var height: Float = 0
    /// Average character width in text units; 0 keeps the font's own proportions.
    public var width: Float = 0
    /// 100...900 (400 regular, 700 bold); 0 is the default weight.
    public var weight: UInt16 = 0
    public var italic = false
    public var underline = false
    public var strike = false
    /// LOGFONT character set (0 ANSI, 2 SYMBOL, 238 EASTEUROPE…).
    public var charset: UInt8 = 0

    public init(
        family: String = "", height: Float = 0, width: Float = 0, weight: UInt16 = 0, italic: Bool = false,
        underline: Bool = false, strike: Bool = false, charset: UInt8 = 0
    ) {
        self.family = family
        self.height = height
        self.width = width
        self.weight = weight
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.charset = charset
    }

    /// Two fonts are the same when every field matches, strings compared scalar for scalar as Rust does.
    public static func == (a: MetafileFont, b: MetafileFont) -> Bool {
        a.family.unicodeScalars.elementsEqual(b.family.unicodeScalars) && a.height == b.height && a.width == b.width
            && a.weight == b.weight && a.italic == b.italic && a.underline == b.underline && a.strike == b.strike
            && a.charset == b.charset
    }
}

/// Where the reference point sits on the string horizontally (TA_LEFT, TA_CENTER, TA_RIGHT).
public enum MetafileHAlign: Sendable, Equatable {
    case left, center, right
}

/// Where the reference point sits vertically (TA_TOP, TA_BASELINE, TA_BOTTOM): the top of the character cell,
/// the baseline or the bottom of the cell.
public enum MetafileVAlign: Sendable, Equatable {
    case top, baseline, bottom
}

/// One string drawn by EXTTEXTOUT, TEXTOUT or SMALLTEXTOUT.
public struct MetafileText: Equatable, Sendable {
    /// Text space to picture space as affine coefficients `[a, b, c, d, e, f]` (`x' = a·x + c·y + e`,
    /// `y' = b·x + d·y + f`, kurbo's order). Text space has x along the baseline and y down, in the metafile's
    /// logical units, with the reference point at the origin. Escapement and the mapping are folded in; glyphs
    /// are never mirrored.
    public var transform: [Double]
    public var text: String
    /// Advance after each character of `text` (one per Unicode scalar), in text units (the dx array). Empty
    /// when the file gives none: the font's own advances apply.
    public var dx: [Float]
    public var font: MetafileFont
    public var color: MetafileColor
    /// Colour filled behind the character cells (OPAQUE background mode); nil when transparent.
    public var background: MetafileColor?
    public var hAlign: MetafileHAlign
    public var vAlign: MetafileVAlign
    /// Clip rectangle `[x0, y0, x1, y1]` in picture units (ETO_CLIPPED).
    public var clip: SIMD4<Float>?
    /// Clip region from the device context, in picture units. nil is the default clip. Drawn together with
    /// `clip` when both are set.
    public var region: [SIMD4<Float>]?

    public static func == (a: MetafileText, b: MetafileText) -> Bool {
        a.transform == b.transform && a.text.unicodeScalars.elementsEqual(b.text.unicodeScalars) && a.dx == b.dx
            && a.font == b.font && a.color == b.color && a.background == b.background && a.hAlign == b.hAlign
            && a.vAlign == b.vAlign && a.clip == b.clip && a.region == b.region
    }
}

/// TA_UPDATECP: the string starts at the current position, which moves past it.
let taUpdateCP: UInt32 = 0x0001
/// ETO_OPAQUE fills the rectangle with the background colour; ETO_CLIPPED clips the text to it.
let etoOpaque: UInt32 = 0x0002
let etoClipped: UInt32 = 0x0004
/// The string holds glyph indices, not characters (drawn only when the font matches).
let etoGlyphIndex: UInt32 = 0x0010
/// The dx array holds (dx, dy) pairs.
let etoPDY: UInt32 = 0x2000
/// Longest string kept from one record.
let maxChars = 16_384

/// Horizontal and vertical alignment from a TA_* word (the vertical bits are 0 top, 8 bottom, 24 baseline; the
/// horizontal ones 0 left, 2 right, 6 center).
func align(_ ta: UInt32) -> (MetafileHAlign, MetafileVAlign) {
    let h: MetafileHAlign = switch ta & 0x06 {
    case 6: .center
    case 2: .right
    default: .left
    }
    let v: MetafileVAlign = switch ta & 0x18 {
    case 0x18: .baseline
    case 0x08: .bottom
    default: .top
    }
    return (h, v)
}

/// Decodes 8-bit text in `charset` to one character per byte, and merges `dx` to match: a double-byte
/// character set's lead and trail bytes become one blank (its glyphs are not decoded) whose advance is the sum
/// of both. `dx` may be empty.
func decodeBytes(_ bytes: [UInt8], _ charset: UInt8, _ dx: [Float]) -> (String, [Float]) {
    var s = String.UnicodeScalarView()
    var outDx: [Float] = []
    let dbcs = [128, 129, 130, 134, 136].contains(charset)
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        let n = dbcs && b >= 0x81 && i + 1 < bytes.count ? 2 : 1
        s.append(n == 2 ? " " : byteChar(b, charset))
        if !dx.isEmpty { outDx.append(rustSum((i ..< i + n).compactMap { dx.at($0) })) }
        i += n
    }
    return (String(s), outDx)
}

/// UTF-16 text to a string with one dx entry per character: a surrogate pair takes the sum of its two advances.
/// Unpaired surrogates become U+FFFD.
func decodeUTF16(_ units: [UInt16], _ dx: [Float]) -> (String, [Float]) {
    var s = String.UnicodeScalarView()
    var outDx: [Float] = []
    var i = 0
    var k = 0
    while k < units.count {
        let u = units[k]
        var c: Unicode.Scalar = "\u{FFFD}"
        var n = 1
        if (0xD800 ..< 0xDC00).contains(u), let lo = units.at(k + 1), (0xDC00 ..< 0xE000).contains(lo) {
            let v = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(lo) - 0xDC00)
            c = Unicode.Scalar(v) ?? "\u{FFFD}"
            n = 2
        } else if !(0xD800 ..< 0xE000).contains(u) {
            c = Unicode.Scalar(u) ?? "\u{FFFD}"
        }
        // Rust counts the advances by the decoded character's UTF-16 length (an unpaired surrogate's
        // replacement is one unit).
        s.append(c)
        if !dx.isEmpty { outDx.append(rustSum((i ..< i + n).compactMap { dx.at($0) })) }
        i += n
        k += n
    }
    return (String(s), outDx)
}

/// One byte in a single-byte Windows code page. Symbol fonts keep their codes in the private-use range
/// (U+F000 + code), where symbol fonts map them.
private func byteChar(_ b: UInt8, _ charset: UInt8) -> Unicode.Scalar {
    if b < 0x80 && charset != Metafile.symbolCharset { return Unicode.Scalar(b) }
    let cp: UInt32 = switch charset {
    case Metafile.symbolCharset: 0xF000 | UInt32(b)
    case 238: high(b, cp1250)
    case 204: high(b, cp1251)
    default: high(b, cp1252)
    }
    return Unicode.Scalar(cp) ?? "\u{FFFD}"
}

/// The code point of byte `b` (0x80...0xFF) from a table of the upper half; 0 entries are undefined bytes,
/// drawn as U+FFFD.
private func high(_ b: UInt8, _ table: [UInt16]) -> UInt32 {
    guard let v = table.at(Int(b &- 0x80)), v != 0 else { return 0xFFFD }
    return UInt32(v)
}

/// Windows-1252 (Western) 0x80...0xFF: the upper half of Latin-1 with typographic marks in 0x80...0x9F.
private let cp1252: [UInt16] = {
    let low: [UInt16] = [
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    ]
    return (0 ..< 128).map { $0 < 32 ? low[$0] : 0x80 + UInt16($0) }
}()

/// Windows-1250 (Central European) 0x80...0xFF.
private let cp1250: [UInt16] = [
    0x20AC, 0, 0x201A, 0, 0x201E, 0x2026, 0x2020, 0x2021, 0, 0x2030, 0x0160, 0x2039, 0x015A, 0x0164, 0x017D, 0x0179,
    0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0, 0x2122, 0x0161, 0x203A, 0x015B, 0x0165, 0x017E, 0x017A,
    0x00A0, 0x02C7, 0x02D8, 0x0141, 0x00A4, 0x0104, 0x00A6, 0x00A7, 0x00A8, 0x00A9, 0x015E, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x017B,
    0x00B0, 0x00B1, 0x02DB, 0x0142, 0x00B4, 0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x0105, 0x015F, 0x00BB, 0x013D, 0x02DD, 0x013E, 0x017C,
    0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7, 0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
    0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7, 0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
    0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7, 0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
    0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7, 0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9,
]

/// Windows-1251 (Cyrillic) 0x80...0xFF; 0xC0...0xFF are А...я in order.
private let cp1251: [UInt16] = {
    let low: [UInt16] = [
        0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
        0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
        0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
        0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    ]
    return (0 ..< 128).map { $0 < 64 ? low[$0] : 0x0410 + UInt16($0 - 64) }
}()
