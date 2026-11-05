// CNXML — quick-xml 0.41.0's events (src/events/mod.rs, src/name.rs; MIT, © Johann Tuffe and the quick-xml
// contributors). An event's bytes are a slice of the reader's input, so reading copies nothing; a slice keeps its
// input's indices (use `startIndex`, or the accessors here, never offsets from 0).

/// `QName`: an element or attribute name as written, prefix included.
public struct XMLQName: Sendable, Hashable, CustomStringConvertible {
    public var bytes: ArraySlice<UInt8>

    public init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }
    public init(_ bytes: [UInt8]) { self.bytes = bytes[...] }
    public init(_ s: String) { bytes = Array(s.utf8)[...] }

    /// The first `:`.
    var colon: Int? { bytes.firstIndex(of: 0x3A) }

    /// After the first `:`, or the whole name.
    public var localName: ArraySlice<UInt8> {
        guard let c = colon else { return bytes }
        return bytes[(c + 1)...] // never-crash: c < endIndex
    }

    /// Before the first `:`, or nil without one.
    public var prefix: ArraySlice<UInt8>? {
        guard let c = colon else { return nil }
        return bytes[..<c]
    }

    /// `as_namespace_binding`: `xmlns` is the default namespace (`.some(nil)`), `xmlns:p` binds `p`; anything else
    /// is nil.
    public var namespaceBinding: ArraySlice<UInt8>?? {
        guard bytes.starts(with: "xmlns".utf8) else { return nil }
        let after = bytes.index(bytes.startIndex, offsetBy: 5)
        if after == bytes.endIndex { return .some(nil) }
        if bytes[after] == 0x3A { return .some(bytes[(after + 1)...]) } // never-crash: after < endIndex
        return nil
    }

    public static func == (a: XMLQName, b: XMLQName) -> Bool { a.bytes.elementsEqual(b.bytes) }
    public func hash(into h: inout Hasher) { h.combine(Array(bytes)) }
    public var description: String { String(decoding: bytes, as: UTF8.self) }
}

/// `BytesStart`: the content of a start or empty tag between `<` and `>` (or `/>`): the name, then the attributes
/// as written.
public struct XMLStart: Sendable, Equatable {
    public internal(set) var buf: ArraySlice<UInt8>
    public internal(set) var nameLen: Int

    init(wrap buf: ArraySlice<UInt8>, nameLen: Int) {
        self.buf = buf
        self.nameLen = nameLen
    }

    /// `BytesStart::new`: a tag with this name and no attributes.
    public init(name: some Sequence<UInt8>) {
        buf = Array(name)[...]
        nameLen = buf.count
    }

    public init(name: String) { self.init(name: name.utf8) }

    /// `BytesStart::from_content`: `content` holds the name (its first `nameLen` bytes) and the attributes.
    public init(content: String, nameLen: Int) {
        buf = Array(content.utf8)[...]
        self.nameLen = Swift.max(0, Swift.min(nameLen, buf.count))
    }

    public var name: XMLQName { XMLQName(buf.prefix(nameLen)) }
    public var localName: ArraySlice<UInt8> { name.localName }

    /// `attributes_raw`: everything after the name.
    public var attributesRaw: ArraySlice<UInt8> { buf.dropFirst(nameLen) }

    /// `attributes()`: duplicates are checked; `.withChecks(false)` turns that off.
    public func attributes() -> XMLAttributes { XMLAttributes(buf, offset: nameLen) }

    /// `try_get_attribute`: the first attribute named `name` exactly, with duplicate checks off. An attribute that
    /// doesn't parse before it is found is an error.
    public func tryGetAttribute(_ name: some Collection<UInt8>) throws(XMLAttrError) -> XMLAttribute? {
        for a in attributes().withChecks(false) {
            let a = try a.get()
            if a.key.bytes.elementsEqual(name) { return a }
        }
        return nil
    }

    /// `push_attribute`: ` key="value"`, the value as given (already escaped).
    public mutating func pushAttribute(_ attr: XMLAttribute) {
        buf.append(0x20)
        buf.append(contentsOf: attr.key.bytes)
        buf.append(contentsOf: "=\"".utf8)
        buf.append(contentsOf: attr.value)
        buf.append(0x22)
    }

    /// `push_attribute((key, value))` from two strings: the value is escaped (`escape`).
    public mutating func pushAttribute(_ key: String, _ value: String) {
        pushAttribute(XMLAttribute(key: XMLQName(key), value: Array(XMLEscape.escape(value).utf8)[...]))
    }

    /// `clear_attributes`.
    public mutating func clearAttributes() {
        buf = buf.prefix(nameLen)
    }

    /// `set_name`.
    public mutating func setName(_ name: some Collection<UInt8>) {
        let rest = buf.dropFirst(nameLen)
        buf = (Array(name) + rest)[...]
        nameLen = name.count
    }

    /// `to_end`: the matching end tag.
    public var toEnd: XMLEnd { XMLEnd(name: name.bytes) }

    public static func == (a: XMLStart, b: XMLStart) -> Bool { a.nameLen == b.nameLen && a.buf.elementsEqual(b.buf) }
}

/// `BytesEnd`: the name in an end tag (trailing whitespace trimmed when the reader trims it).
public struct XMLEnd: Sendable, Equatable {
    public var nameBytes: ArraySlice<UInt8>

    public init(name: ArraySlice<UInt8>) { nameBytes = name }
    public init(name: String) { nameBytes = Array(name.utf8)[...] }

    public var name: XMLQName { XMLQName(nameBytes) }
    public var localName: ArraySlice<UInt8> { name.localName }

    public static func == (a: XMLEnd, b: XMLEnd) -> Bool { a.nameBytes.elementsEqual(b.nameBytes) }
}

/// `BytesText` (text, comments, DOCTYPE), `BytesCData` and `BytesRef` (the name between `&` and `;`): content as
/// written, nothing unescaped.
public struct XMLText: Sendable, Equatable {
    public var content: ArraySlice<UInt8>

    public init(raw content: ArraySlice<UInt8>) { self.content = content }
    /// `BytesText::from_escaped`.
    public init(escaped: String) { content = Array(escaped.utf8)[...] }
    /// `BytesText::new`: `text` escaped (`escape`).
    public init(_ text: String) { content = Array(XMLEscape.escape(text).utf8)[...] }

    public var isEmpty: Bool { content.isEmpty }

    /// `decode`: the content as UTF-8.
    public func decode() throws(XMLEncodingError) -> String { try decodeUTF8(content) }

    /// `xml_content`: decoded, with line ends normalised for `version`.
    public func xmlContent(_ version: XMLVersion) throws(XMLEncodingError) -> String {
        let s = try decode()
        return version == .explicit1_1 ? XMLEscape.normalizeXML11EOLs(s) : XMLEscape.normalizeXML10EOLs(s)
    }

    /// `BytesRef::is_char_ref`.
    public var isCharRef: Bool { content.first == 0x23 }

    /// `BytesRef::resolve_char_ref`: a character reference's character; nil for an entity reference.
    public func resolveCharRef() throws(XMLError) -> Unicode.Scalar? {
        let s: String
        do { s = try decode() } catch { throw .encoding(error) }
        guard s.utf8.first == 0x23 else { return nil }
        do {
            return try XMLEscape.parseNumber(s.utf8.dropFirst())
        } catch {
            throw .escape(.invalidCharRef(error))
        }
    }

    public static func == (a: XMLText, b: XMLText) -> Bool { a.content.elementsEqual(b.content) }
}

/// `BytesPI`: the content between `<?` and `?>`; the target is its first `targetLen` bytes.
public struct XMLPI: Sendable, Equatable {
    public var content: ArraySlice<UInt8>
    public var targetLen: Int

    public init(raw content: ArraySlice<UInt8>, targetLen: Int) {
        self.content = content
        self.targetLen = targetLen
    }

    public var target: ArraySlice<UInt8> { content.prefix(targetLen) }

    public static func == (a: XMLPI, b: XMLPI) -> Bool { a.targetLen == b.targetLen && a.content.elementsEqual(b.content) }
}

/// `BytesDecl`: an XML declaration, read as a start tag named `xml`.
public struct XMLDecl: Sendable, Equatable {
    public var start: XMLStart
    public init(start: XMLStart) { self.start = start }
    public var content: ArraySlice<UInt8> { start.buf }
}

/// `quick_xml::events::Event`.
public enum XMLEvent: Sendable, Equatable {
    case start(XMLStart)
    case end(XMLEnd)
    case empty(XMLStart)
    case text(XMLText)
    case cdata(XMLText)
    case comment(XMLText)
    case decl(XMLDecl)
    case pi(XMLPI)
    case docType(XMLText)
    case generalRef(XMLText)
    case eof

    /// `Deref`: the event's bytes as it holds them.
    public var bytes: ArraySlice<UInt8> {
        switch self {
        case .start(let e), .empty(let e): e.buf
        case .end(let e): e.nameBytes
        case .text(let t), .cdata(let t), .comment(let t), .docType(let t), .generalRef(let t): t.content
        case .decl(let d): d.start.buf
        case .pi(let p): p.content
        case .eof: []
        }
    }
}
