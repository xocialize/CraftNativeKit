// CNXML — quick-xml 0.41.0's errors, with the messages its `Display` impls print (src/errors.rs, src/escape.rs,
// src/encoding.rs, src/events/attributes.rs, src/name.rs; MIT, © Johann Tuffe and the quick-xml contributors), and
// Rust's `str::from_utf8` error (core::str::Utf8Error) that quick-xml wraps when it decodes bytes. Callers print
// these with `"\(error)"`, the way Rust code prints them with `format!("{e}")` or `e.to_string()`.

/// `quick_xml::errors::SyntaxError`: markup the reader can't end.
public enum XMLSyntaxError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidBangMarkup
    case unclosedPI
    case unclosedXmlDecl
    case unclosedComment
    case unclosedDoctype
    case unclosedCData
    case unclosedTag
    case unclosedSingleQuotedAttributeValue
    case unclosedDoubleQuotedAttributeValue

    public var description: String {
        switch self {
        case .invalidBangMarkup: "unknown or missed symbol in markup"
        case .unclosedPI: "processing instruction not closed: `?>` not found before end of input"
        case .unclosedXmlDecl: "XML declaration not closed: `?>` not found before end of input"
        case .unclosedComment: "comment not closed: `-->` not found before end of input"
        case .unclosedDoctype: "DOCTYPE not closed: `>` not found before end of input"
        case .unclosedCData: "CDATA not closed: `]]>` not found before end of input"
        case .unclosedTag: "tag not closed: `>` not found before end of input"
        case .unclosedSingleQuotedAttributeValue: "attribute value not closed: `'` not found before end of input"
        case .unclosedDoubleQuotedAttributeValue: "attribute value not closed: `\"` not found before end of input"
        }
    }
}

/// `quick_xml::errors::IllFormedError`: a well-delimited construct that breaks a rule. The reader can go on after
/// one of these.
public enum XMLIllFormedError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingDeclVersion(String?)
    case unknownVersion
    case missingDoctypeName
    case missingEndTag(String)
    case unmatchedEndTag(String)
    case mismatchedEndTag(expected: String, found: String)
    case doubleHyphenInComment
    case unclosedReference

    public var description: String {
        switch self {
        case .missingDeclVersion(nil): "an XML declaration does not contain `version` attribute"
        case .missingDeclVersion(let attr?):
            "an XML declaration must start with `version` attribute, but in starts with `\(attr)`"
        case .unknownVersion: "unknown XML version: either 1.0 or 1.1 is expected"
        case .missingDoctypeName: "`<!DOCTYPE>` declaration does not contain a name of a document type"
        case .missingEndTag(let tag): "start tag not closed: `</\(tag)>` not found before end of input"
        case .unmatchedEndTag(let tag): "close tag `</\(tag)>` does not match any open tag"
        case .mismatchedEndTag(let expected, let found): "expected `</\(expected)>`, but `</\(found)>` was found"
        case .doubleHyphenInComment: "forbidden string `--` was found in a comment"
        case .unclosedReference: "entity or character reference not closed: `;` not found before end of input"
        }
    }
}

/// `core::str::Utf8Error`: where `str::from_utf8` stopped, and how long the invalid sequence is (nil when the input
/// ends inside a sequence).
public struct RustUTF8Error: Error, Sendable, Equatable, CustomStringConvertible {
    public let validUpTo: Int
    public let errorLen: Int?

    public init(validUpTo: Int, errorLen: Int?) {
        self.validUpTo = validUpTo
        self.errorLen = errorLen
    }

    public var description: String {
        if let errorLen { return "invalid utf-8 sequence of \(errorLen) bytes from index \(validUpTo)" }
        return "incomplete utf-8 byte sequence from index \(validUpTo)"
    }

    /// The error `str::from_utf8` reports for `bytes`, or nil when they are valid UTF-8
    /// (core::str::validations::run_utf8_validation).
    public static func check(_ bytes: some Collection<UInt8>) -> RustUTF8Error? {
        let b = Array(bytes)
        let n = b.count
        var i = 0
        while i < n {
            let first = b[i] // never-crash: i < n
            if first < 0x80 {
                i += 1
                continue
            }
            let start = i
            func at(_ k: Int) -> UInt8? { k < n ? b[k] : nil } // never-crash: bounds checked
            func isCont(_ x: UInt8) -> Bool { x & 0xC0 == 0x80 }
            switch first {
            case 0xC2 ... 0xDF:
                guard let x = at(i + 1) else { return RustUTF8Error(validUpTo: start, errorLen: nil) }
                guard isCont(x) else { return RustUTF8Error(validUpTo: start, errorLen: 1) }
                i += 2
            case 0xE0 ... 0xEF:
                guard let x = at(i + 1) else { return RustUTF8Error(validUpTo: start, errorLen: nil) }
                let ok: Bool = switch first {
                case 0xE0: x >= 0xA0 && x <= 0xBF
                case 0xED: x >= 0x80 && x <= 0x9F
                default: x >= 0x80 && x <= 0xBF
                }
                guard ok else { return RustUTF8Error(validUpTo: start, errorLen: 1) }
                guard let y = at(i + 2) else { return RustUTF8Error(validUpTo: start, errorLen: nil) }
                guard isCont(y) else { return RustUTF8Error(validUpTo: start, errorLen: 2) }
                i += 3
            case 0xF0 ... 0xF4:
                guard let x = at(i + 1) else { return RustUTF8Error(validUpTo: start, errorLen: nil) }
                let ok: Bool = switch first {
                case 0xF0: x >= 0x90 && x <= 0xBF
                case 0xF4: x >= 0x80 && x <= 0x8F
                default: x >= 0x80 && x <= 0xBF
                }
                guard ok else { return RustUTF8Error(validUpTo: start, errorLen: 1) }
                guard let y = at(i + 2) else { return RustUTF8Error(validUpTo: start, errorLen: nil) }
                guard isCont(y) else { return RustUTF8Error(validUpTo: start, errorLen: 2) }
                guard let z = at(i + 3) else { return RustUTF8Error(validUpTo: start, errorLen: nil) }
                guard isCont(z) else { return RustUTF8Error(validUpTo: start, errorLen: 3) }
                i += 4
            default:
                return RustUTF8Error(validUpTo: start, errorLen: 1)
            }
        }
        return nil
    }
}

/// `quick_xml::encoding::EncodingError` without the `encoding` feature: bytes that aren't UTF-8.
public enum XMLEncodingError: Error, Sendable, Equatable, CustomStringConvertible {
    case utf8(RustUTF8Error)

    public var description: String {
        switch self {
        case .utf8(let e): "cannot decode input using UTF-8: \(e)"
        }
    }
}

/// `core::num::ParseIntError`'s kinds that `u32::from_str_radix` gives.
public enum RustParseIntError: Error, Sendable, Equatable, CustomStringConvertible {
    case empty
    case invalidDigit
    case posOverflow

    public var description: String {
        switch self {
        case .empty: "cannot parse integer from empty string"
        case .invalidDigit: "invalid digit found in string"
        case .posOverflow: "number too large to fit in target type"
        }
    }
}

/// `quick_xml::escape::ParseCharRefError`.
public enum XMLCharRefError: Error, Sendable, Equatable, CustomStringConvertible {
    case unexpectedSign
    case invalidNumber(RustParseIntError)
    case invalidCodepoint(UInt32)
    case illegalCharacter(UInt32)

    public var description: String {
        switch self {
        case .unexpectedSign: "unexpected number sign"
        case .invalidNumber(let e): e.description
        case .invalidCodepoint(let n): "`\(n)` is not a valid codepoint"
        case .illegalCharacter(let n): "0x\(String(n, radix: 16)) character is not permitted in XML"
        }
    }
}

/// `quick_xml::escape::EscapeError`. Ranges are byte offsets in the escaped text, printed as Rust's `{:?}` of a
/// `Range` prints them (`3..7`).
public enum XMLEscapeError: Error, Sendable, Equatable, CustomStringConvertible {
    case unrecognizedEntity(Range<Int>, String)
    case unterminatedEntity(Range<Int>)
    case invalidCharRef(XMLCharRefError)
    case tooManyNestedEntities

    public var description: String {
        switch self {
        case .unrecognizedEntity(let r, let s): "at \(r.lowerBound)..\(r.upperBound): unrecognized entity `\(s)`"
        case .unterminatedEntity(let r):
            "Error while escaping character at range \(r.lowerBound)..\(r.upperBound): Cannot find ';' after '&'"
        case .invalidCharRef(let e): "invalid character reference: \(e)"
        case .tooManyNestedEntities: "too many nested entities in an attribute value"
        }
    }
}

/// `quick_xml::events::attributes::AttrError`. Positions are byte offsets in the start tag's content (after `<`).
public enum XMLAttrError: Error, Sendable, Equatable, CustomStringConvertible {
    case expectedEq(Int)
    case expectedValue(Int)
    case unquotedValue(Int)
    case expectedQuote(Int, UInt8)
    case duplicated(Int, Int)

    public var description: String {
        switch self {
        case .expectedEq(let p): "position \(p): attribute key must be directly followed by `=` or space"
        case .expectedValue(let p): "position \(p): `=` must be followed by an attribute value"
        case .unquotedValue(let p): "position \(p): attribute value must be enclosed in `\"` or `'`"
        case .expectedQuote(let p, let q):
            "position \(p): missing closing quote `\(Character(Unicode.Scalar(q)))` in attribute value"
        case .duplicated(let a, let b): "position \(a): duplicated attribute, previous declaration at position \(b)"
        }
    }
}

/// `quick_xml::name::NamespaceError`.
public enum XMLNamespaceError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownPrefix([UInt8])
    case invalidXmlPrefixBind([UInt8])
    case invalidXmlnsPrefixBind([UInt8])
    case invalidPrefixForXml([UInt8])
    case invalidPrefixForXmlns([UInt8])
    case tooManyDeclarations(Int)

    public var description: String {
        switch self {
        case .unknownPrefix(let p): "unknown namespace prefix '\(byteString(p))'"
        case .invalidXmlPrefixBind(let ns): "the namespace prefix 'xml' cannot be bound to '\(byteString(ns))'"
        case .invalidXmlnsPrefixBind(let ns): "the namespace prefix 'xmlns' cannot be bound to '\(byteString(ns))'"
        case .invalidPrefixForXml(let p):
            "the namespace prefix '\(byteString(p))' cannot be bound to 'http://www.w3.org/XML/1998/namespace'"
        case .invalidPrefixForXmlns(let p):
            "the namespace prefix '\(byteString(p))' cannot be bound to 'http://www.w3.org/2000/xmlns/'"
        case .tooManyDeclarations(let limit):
            "start tag declares more than \(limit) namespace bindings; raise the limit with NamespaceResolver::set_max_declarations_per_element"
        }
    }
}

/// `quick_xml::utils::write_byte_string`: the bytes in double quotes, printable ASCII as itself, `"` escaped, and
/// anything else as `{:#02X}` (`0xA`, `0xFF`).
func byteString(_ bytes: [UInt8]) -> String {
    var s = "\""
    for b in bytes {
        switch b {
        case 32 ... 33, 35 ... 126: s.unicodeScalars.append(Unicode.Scalar(b))
        case 34: s += "\\\""
        default: s += "0x" + String(b, radix: 16, uppercase: true)
        }
    }
    return s + "\""
}

/// `quick_xml::Error`, the error every reading call returns. `Io` can't happen over bytes in memory.
public enum XMLError: Error, Sendable, Equatable, CustomStringConvertible {
    case syntax(XMLSyntaxError)
    case illFormed(XMLIllFormedError)
    case invalidAttr(XMLAttrError)
    case encoding(XMLEncodingError)
    case escape(XMLEscapeError)
    case namespace(XMLNamespaceError)

    public var description: String {
        switch self {
        case .syntax(let e): "syntax error: \(e)"
        case .illFormed(let e): "ill-formed document: \(e)"
        case .invalidAttr(let e): "error while parsing attribute: \(e)"
        case .encoding(let e): e.description
        case .escape(let e): e.description
        case .namespace(let e): e.description
        }
    }
}

/// `std::str::from_utf8(bytes)` as quick-xml's `Decoder::decode` does it without the `encoding` feature.
@inlinable
public func decodeUTF8(_ bytes: ArraySlice<UInt8>) throws(XMLEncodingError) -> String {
    if let s = String(validating: bytes, as: UTF8.self) { return s }
    throw .utf8(RustUTF8Error.check(bytes) ?? RustUTF8Error(validUpTo: 0, errorLen: 1))
}
