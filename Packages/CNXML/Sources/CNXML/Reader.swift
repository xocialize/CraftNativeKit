// CNXML — the pull reader: a port of quick-xml 0.41.0's `Reader` over a byte slice (src/reader/mod.rs,
// src/reader/state.rs, src/reader/slice_reader.rs, src/parser/*.rs; MIT, © Johann Tuffe and the quick-xml
// contributors), without the `encoding` feature. quick-xml's buffered reader (`read_event_into` over `&[u8]`) sees
// the whole input as one chunk and gives the same events, positions and errors, so this one type serves both.
//
// Work is linear in the input: every step consumes at least one byte or ends the document, and events are slices
// of the input, never copies.

/// `quick_xml::reader::Config`, with quick-xml's defaults.
public struct XMLReaderConfig: Sendable, Equatable {
    /// A `&` without its `;` reads as text instead of an error.
    public var allowDanglingAmp = false
    /// An end tag with no open element is returned instead of an error.
    public var allowUnmatchedEnds = false
    /// `--` inside a comment is an error.
    public var checkComments = false
    /// An end tag must name the element it closes.
    public var checkEndNames = true
    /// `<a/>` reads as `Start` then `End`.
    public var expandEmptyElements = false
    /// Whitespace after the name in an end tag is dropped.
    public var trimMarkupNamesInClosingTags = true
    /// Whitespace at the start of text is skipped.
    public var trimTextStart = false
    /// Whitespace at the end of text is dropped.
    public var trimTextEnd = false

    public init() {}

    /// `trim_text`.
    public mutating func trimText(_ trim: Bool) {
        trimTextStart = trim
        trimTextEnd = trim
    }

    /// `enable_all_checks`.
    public mutating func enableAllChecks(_ on: Bool) {
        checkComments = on
        checkEndNames = on
    }
}

/// `quick_xml::Reader<&[u8]>`.
public struct XMLReader: Sendable {
    enum ParseState: Sendable {
        case initial, insideRef, insideMarkup, insideText, insideEmpty, done
    }

    let bytes: [UInt8]
    /// The next unread byte in `bytes`.
    var cursor = 0
    /// `buffer_position`: bytes consumed since the start (a removed BOM isn't counted).
    public private(set) var bufferPosition = 0
    /// `error_position`: where the last error was found.
    public private(set) var errorPosition = 0
    var state = ParseState.initial
    public var config = XMLReaderConfig()
    /// The names of the open elements, end to end, and where each starts.
    var openedBuffer: [UInt8] = []
    var openedStarts: [Int] = []

    /// `Reader::from_reader` over bytes.
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init(_ bytes: ArraySlice<UInt8>) { self.bytes = Array(bytes) }
    /// `Reader::from_str`.
    public init(_ text: String) { bytes = Array(text.utf8) }

    /// The whole input, for callers that slice it by positions (`buffer_position` is an offset from `inputStart`).
    public var input: [UInt8] { bytes }
    /// Where position 0 is in `input`: after a UTF-8 BOM, once the first event has removed it.
    public private(set) var inputStart = 0

    // MARK: - Reading

    /// `read_event` (and `read_event_into`): the next event. After a syntax error every call returns `.eof`; after an
    /// ill-formed one, reading goes on.
    public mutating func readEvent() throws(XMLError) -> XMLEvent {
        let result = readEventImpl()
        switch result {
        case .failure(.illFormed): break
        case .failure, .success(.eof): state = .done
        default: break
        }
        return try result.get()
    }

    mutating func readEventImpl() -> Result<XMLEvent, XMLError> {
        while true {
            switch state {
            case .initial:
                if bytes.count - cursor >= 3, bytes[cursor] == 0xEF, bytes[cursor + 1] == 0xBB, bytes[cursor + 2] == 0xBF { // never-crash: checked
                    cursor += 3
                    inputStart = cursor
                }
                state = .insideText
                continue
            case .insideRef:
                let start = bufferPosition
                switch readRef() {
                case .ref(let r):
                    state = .insideText
                    // Without the `&` and the `;`.
                    return .success(.generalRef(XMLText(raw: bytes[(r.lowerBound + 1) ..< (r.upperBound - 1)]))) // never-crash: r holds `&…;`
                case .upToEof(let r):
                    state = .done
                    if config.allowDanglingAmp { return .success(.text(emitText(r))) }
                    errorPosition = start
                    return .failure(.illFormed(.unclosedReference))
                case .upToRef(let r):
                    if config.allowDanglingAmp { return .success(.text(emitText(r))) }
                    errorPosition = start
                    return .failure(.illFormed(.unclosedReference))
                case .upToMarkup(let r):
                    state = .insideMarkup
                    if config.allowDanglingAmp { return .success(.text(emitText(r))) }
                    errorPosition = start
                    return .failure(.illFormed(.unclosedReference))
                }
            case .insideText:
                if config.trimTextStart { skipWhitespace() }
                switch readText() {
                case .markup:
                    state = .insideMarkup
                    continue
                case .ref:
                    state = .insideRef
                    continue
                case .upToMarkup(let r):
                    state = .insideMarkup
                    return .success(.text(emitText(r)))
                case .upToRef(let r):
                    state = .insideRef
                    return .success(.text(emitText(r)))
                case .upToEof(let r):
                    state = .done
                    let t = emitText(r)
                    return .success(t.isEmpty ? .eof : .text(t))
                }
            case .insideMarkup:
                return readUntilClose()
            case .insideEmpty:
                return .success(.end(closeExpandedEmpty()))
            case .done:
                return .success(.eof)
            }
        }
    }

    enum TextResult {
        case markup, ref
        case upToMarkup(Range<Int>), upToRef(Range<Int>), upToEof(Range<Int>)
    }

    enum RefResult {
        case ref(Range<Int>), upToEof(Range<Int>), upToRef(Range<Int>), upToMarkup(Range<Int>)
    }

    /// `read_text`: up to the next `<` or `&`.
    mutating func readText() -> TextResult {
        var i = cursor
        let n = bytes.count
        while i < n {
            let b = bytes[i] // never-crash: i < n
            if b == 0x3C || b == 0x26 { break }
            i += 1
        }
        if i == n {
            let r = cursor ..< n
            bufferPosition += n - cursor
            cursor = n
            return .upToEof(r)
        }
        if i == cursor { return bytes[i] == 0x3C ? .markup : .ref } // never-crash: i < n
        let r = cursor ..< i
        bufferPosition += i - cursor
        cursor = i
        return bytes[i] == 0x3C ? .upToMarkup(r) : .upToRef(r) // never-crash: i < n
    }

    /// `read_ref`: at a `&`, to its `;`, or to the next `&` or `<`.
    mutating func readRef() -> RefResult {
        let n = bytes.count
        var i = cursor + 1
        while i < n {
            let b = bytes[i] // never-crash: i < n
            if b == 0x3B || b == 0x26 || b == 0x3C { break }
            i += 1
        }
        if i >= n {
            let r = cursor ..< n
            bufferPosition += n - cursor
            cursor = n
            return .upToEof(r)
        }
        if bytes[i] == 0x3B { // never-crash: i < n
            let r = cursor ..< (i + 1)
            bufferPosition += i + 1 - cursor
            cursor = i + 1
            return .ref(r)
        }
        let r = cursor ..< i
        bufferPosition += i - cursor
        cursor = i
        return bytes[i] == 0x26 ? .upToRef(r) : .upToMarkup(r) // never-crash: i < n
    }

    mutating func skipWhitespace() {
        while cursor < bytes.count, isXMLWhitespace(bytes[cursor]) { // never-crash: checked
            cursor += 1
            bufferPosition += 1
        }
    }

    /// `read_until_close`: the markup starting at the `<` under the cursor.
    mutating func readUntilClose() -> Result<XMLEvent, XMLError> {
        state = .insideText
        let start = bufferPosition
        guard cursor + 1 < bytes.count else {
            errorPosition = start
            return .failure(.syntax(.unclosedTag))
        }
        switch bytes[cursor + 1] { // never-crash: checked
        case 0x21: // `!`
            switch readBangElement() {
            case .success(let (kind, r)): return emitBang(kind, r)
            case .failure(let e):
                errorPosition = start
                return .failure(.syntax(e))
            }
        case 0x2F: // `/`
            var p = ElementParser.outside
            switch readWith(&p) {
            case .success(let r): return emitEnd(r)
            case .failure(let e):
                errorPosition = start
                return .failure(.syntax(e))
            }
        case 0x3F: // `?`
            var p = PIParser(seenQuestion: false)
            switch readWith(&p) {
            case .success(let r): return emitQuestionMark(r)
            case .failure(let e):
                errorPosition = start
                return .failure(.syntax(e))
            }
        default:
            var p = ElementParser.outside
            switch readWith(&p) {
            case .success(let r): return .success(emitStart(r))
            case .failure(let e):
                errorPosition = start
                return .failure(.syntax(e))
            }
        }
    }

    /// `read_with`: feeds the rest of the input (from the `<`) to `parser`; the markup through its `>`.
    mutating func readWith<P: MarkupParser>(_ parser: inout P) -> Result<Range<Int>, XMLSyntaxError> {
        let rest = bytes[cursor...] // never-crash: cursor <= count
        if let i = parser.feed(rest) {
            let used = i + 1
            let r = cursor ..< (cursor + used)
            bufferPosition += used
            cursor += used
            return .success(r)
        }
        bufferPosition += rest.count
        cursor = bytes.count
        return .failure(parser.eofError(rest))
    }

    /// `read_bang_element`: `<!` then a comment, CDATA or DOCTYPE, through its `>`.
    mutating func readBangElement() -> Result<(BangType, Range<Int>), XMLSyntaxError> {
        let third: UInt8? = cursor + 2 < bytes.count ? bytes[cursor + 2] : nil // never-crash: checked
        var kind: BangType
        switch third {
        case 0x5B: kind = .cdata
        case 0x2D: kind = .comment
        case 0x44, 0x64: kind = .docType(DTDParser())
        default: return .failure(.invalidBangMarkup)
        }
        let rest = bytes[cursor...] // never-crash: cursor <= count
        if let i = kind.feed(rest) {
            let used = i + 1
            let r = cursor ..< (cursor + used)
            bufferPosition += used
            cursor += used
            return .success((kind, r))
        }
        bufferPosition += rest.count
        cursor = bytes.count
        return .failure(kind.eofError)
    }

    // MARK: - Emitting (state.rs)

    func emitText(_ r: Range<Int>) -> XMLText {
        var content = bytes[r] // never-crash: r from a search
        if config.trimTextEnd {
            if let last = content.lastIndex(where: { !isXMLWhitespace($0) }) {
                content = content[...last]
            } else {
                content = content.prefix(0)
            }
        }
        return XMLText(raw: content)
    }

    mutating func emitBang(_ kind: BangType, _ r: Range<Int>) -> Result<XMLEvent, XMLError> {
        let buf = bytes[r] // never-crash: r from a search
        let len = buf.count
        let s = buf.startIndex
        switch kind {
        case .comment where buf.starts(with: "<!--".utf8):
            if config.checkComments {
                // Search for `--` between `<!--` and `-->`, as quick-xml does (its error offset counts from the
                // last `-` found, not the first).
                var haystack = (s + 4) ..< (s + len - 3)
                var off = 0
                while let p = bytes[haystack].firstIndex(of: 0x2D) { // never-crash: haystack within buf
                    let rel = p - haystack.lowerBound
                    off += rel + 1
                    if s + 4 + off < r.upperBound, bytes[s + 4 + off] == 0x2D { // never-crash: checked
                        errorPosition = bufferPosition - len + 4 + rel
                        return .failure(.illFormed(.doubleHyphenInComment))
                    }
                    haystack = (p + 1) ..< haystack.upperBound
                }
            }
            return .success(.comment(XMLText(raw: bytes[(s + 4) ..< (s + len - 3)]))) // never-crash: `<!--…-->` is 7+ bytes
        case .cdata where buf.starts(with: "<![CDATA[".utf8):
            return .success(.cdata(XMLText(raw: bytes[(s + 9) ..< (s + len - 3)]))) // never-crash: `<![CDATA[…]]>` is 12+ bytes
        case .docType(let p) where p.finished && len >= 9 && zip(buf.prefix(9), "<!DOCTYPE".utf8).allSatisfy({ asciiLower($0) == asciiLower($1) }):
            let inner = bytes[(s + 9) ..< (s + len - 1)] // never-crash: `<!DOCTYPE` and `>`
            if let first = inner.firstIndex(where: { !isXMLWhitespace($0) }) {
                return .success(.docType(XMLText(raw: bytes[first ..< inner.endIndex]))) // never-crash: within inner
            }
            errorPosition = bufferPosition - 1
            return .failure(.illFormed(.missingDoctypeName))
        default:
            errorPosition = bufferPosition - len
            return .failure(.syntax(kind.eofError))
        }
    }

    mutating func emitEnd(_ r: Range<Int>) -> Result<XMLEvent, XMLError> {
        let buf = bytes[r] // never-crash: r from a search
        let content = bytes[(r.lowerBound + 2) ..< (r.upperBound - 1)] // never-crash: `</…>` is 3+ bytes
        var name = content
        if config.trimMarkupNamesInClosingTags, let last = content.lastIndex(where: { !isXMLWhitespace($0) }) {
            name = content[...last]
        }
        if let start = openedStarts.popLast() {
            if config.checkEndNames {
                let expected = openedBuffer[Swift.min(start, openedBuffer.count)...] // never-crash: clamped
                if !name.elementsEqual(expected) {
                    let exp = (try? decodeUTF8(expected)) ?? ""
                    openedBuffer.removeSubrange(Swift.min(start, openedBuffer.count)...)
                    errorPosition = bufferPosition - buf.count
                    return .failure(.illFormed(.mismatchedEndTag(expected: exp, found: (try? decodeUTF8(name)) ?? "")))
                }
            }
            openedBuffer.removeSubrange(Swift.min(start, openedBuffer.count)...)
        } else if !config.allowUnmatchedEnds {
            errorPosition = bufferPosition - buf.count
            return .failure(.illFormed(.unmatchedEndTag((try? decodeUTF8(name)) ?? "")))
        }
        return .success(.end(XMLEnd(name: name)))
    }

    mutating func emitQuestionMark(_ r: Range<Int>) -> Result<XMLEvent, XMLError> {
        let len = r.count
        guard len > 3 else {
            errorPosition = bufferPosition - len
            return .failure(.syntax(PIParser(seenQuestion: false).eofError(bytes[r]))) // never-crash: r from a search
        }
        let content = bytes[(r.lowerBound + 2) ..< (r.upperBound - 2)] // never-crash: len > 3
        let s = content.startIndex
        if content.starts(with: "xml".utf8), content.count == 3 || isXMLWhitespace(content[s + 3]) { // never-crash: count > 3 here
            return .success(.decl(XMLDecl(start: XMLStart(wrap: content, nameLen: 3))))
        }
        return .success(.pi(XMLPI(raw: content, targetLen: nameLen(content))))
    }

    mutating func emitStart(_ r: Range<Int>) -> XMLEvent {
        let content = bytes[(r.lowerBound + 1) ..< r.upperBound] // never-crash: r holds `<…>`
        if content.count >= 2, content.last == 0x3E, content[content.endIndex - 2] == 0x2F { // never-crash: count >= 2
            let inner = content.dropLast(2)
            let e = XMLStart(wrap: inner, nameLen: nameLen(inner))
            if config.expandEmptyElements {
                state = .insideEmpty
                openedStarts.append(openedBuffer.count)
                openedBuffer.append(contentsOf: e.name.bytes)
                return .start(e)
            }
            return .empty(e)
        }
        let inner = content.dropLast(1)
        let e = XMLStart(wrap: inner, nameLen: nameLen(inner))
        openedStarts.append(openedBuffer.count)
        openedBuffer.append(contentsOf: e.name.bytes)
        return .start(e)
    }

    mutating func closeExpandedEmpty() -> XMLEnd {
        state = .insideText
        let start = Swift.min(openedStarts.popLast() ?? openedBuffer.count, openedBuffer.count)
        let name = Array(openedBuffer[start...]) // never-crash: clamped
        openedBuffer.removeSubrange(start...)
        return XMLEnd(name: name[...])
    }

    // MARK: - read_to_end

    /// `read_to_end`: reads past the end tag matching `end` (by name, counting nested starts of the same name), and
    /// returns the span between the start tag just read and that end tag, as positions.
    public mutating func readToEnd(_ end: some Collection<UInt8>) throws(XMLError) -> Range<Int> {
        let trim = config.trimTextStart
        config.trimTextStart = false
        defer { config.trimTextStart = trim }
        let start = bufferPosition
        var depth = 0
        while true {
            let endPos = bufferPosition
            switch try readEvent() {
            case .start(let e) where e.name.bytes.elementsEqual(end): depth += 1
            case .end(let e) where e.nameBytes.elementsEqual(end):
                if depth == 0 { return start ..< endPos }
                depth -= 1
            case .eof:
                let name = Array(end)
                guard let s = String(validating: name, as: UTF8.self) else {
                    throw .encoding(.utf8(RustUTF8Error.check(name) ?? RustUTF8Error(validUpTo: 0, errorLen: 1)))
                }
                throw .illFormed(.missingEndTag(s))
            default: break
            }
        }
    }
}

// MARK: - Helpers

/// quick-xml's `is_whitespace`: space, CR, LF and tab.
@inline(__always)
public func isXMLWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0D || b == 0x0A || b == 0x09 }

@inline(__always)
func asciiLower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 32 : b }

/// `name_len`: bytes up to the first whitespace.
func nameLen(_ b: ArraySlice<UInt8>) -> Int {
    var n = 0
    for x in b {
        if isXMLWhitespace(x) { break }
        n += 1
    }
    return n
}

// MARK: - Parsers (src/parser)

protocol MarkupParser {
    /// The index in `bytes` (from 0) of the `>` that ends the markup, or nil if this chunk doesn't hold it.
    mutating func feed(_ bytes: ArraySlice<UInt8>) -> Int?
    func eofError(_ content: ArraySlice<UInt8>) -> XMLSyntaxError
}

/// `ElementParser`: the first `>` outside quotes.
enum ElementParser: MarkupParser {
    case outside, singleQ, doubleQ

    mutating func feed(_ bytes: ArraySlice<UInt8>) -> Int? {
        let s = bytes.startIndex
        for i in bytes.indices {
            let b = bytes[i] // never-crash: i in indices
            switch (self, b) {
            case (.outside, 0x3E): return i - s
            case (.outside, 0x27): self = .singleQ
            case (.outside, 0x22): self = .doubleQ
            case (.singleQ, 0x27), (.doubleQ, 0x22): self = .outside
            default: break
            }
        }
        return nil
    }

    func eofError(_ content: ArraySlice<UInt8>) -> XMLSyntaxError {
        switch self {
        case .outside: .unclosedTag
        case .singleQ: .unclosedSingleQuotedAttributeValue
        case .doubleQ: .unclosedDoubleQuotedAttributeValue
        }
    }
}

/// `PiParser`: the first `?>`. `seenQuestion` is whether the previous chunk ended with `?`.
struct PIParser: MarkupParser {
    var seenQuestion: Bool

    mutating func feed(_ bytes: ArraySlice<UInt8>) -> Int? {
        let s = bytes.startIndex
        for i in bytes.indices where bytes[i] == 0x3E { // never-crash: i in indices
            if i == s, seenQuestion { return 0 }
            if i > s, bytes[i - 1] == 0x3F { return i - s } // never-crash: i > startIndex
        }
        seenQuestion = bytes.last == 0x3F
        return nil
    }

    func eofError(_ content: ArraySlice<UInt8>) -> XMLSyntaxError {
        let isDecl = content.starts(with: "<?xml".utf8) && {
            let k = content.startIndex + 5
            guard k < content.endIndex else { return true }
            let b = content[k] // never-crash: checked
            return isXMLWhitespace(b) || b == 0x3F
        }()
        return isDecl ? .unclosedXmlDecl : .unclosedPI
    }
}

/// `CommentParser`: the first `-->`, across chunks.
enum CommentParser {
    case seen0, seen1, seen2

    mutating func feed(_ bytes: ArraySlice<UInt8>) -> Int? {
        let r: Int? = switch self {
        case .seen0: Self.seen0(bytes)
        case .seen1: Self.seen1(bytes)
        case .seen2: Self.seen2(bytes)
        }
        if let r { return r }
        if bytes.count >= 2, bytes.suffix(2).elementsEqual([0x2D, 0x2D]) {
            self = .seen2
        } else {
            switch (self, bytes.last) {
            case (.seen0, 0x2D?): self = .seen1
            case (.seen1, 0x2D?): self = .seen2
            case (.seen1, _?): self = .seen0
            case (.seen2, 0x2D?): break
            case (.seen2, _?): self = .seen0
            default: break
            }
        }
        return nil
    }

    static func seen0(_ b: ArraySlice<UInt8>) -> Int? {
        let s = b.startIndex
        for i in b.indices where b[i] == 0x3E { // never-crash: i in indices
            if i - s >= 2, b[i - 1] == 0x2D, b[i - 2] == 0x2D { return i - s + 1 } // never-crash: checked
        }
        return nil
    }

    static func seen1(_ b: ArraySlice<UInt8>) -> Int? {
        if b.starts(with: [0x2D, 0x3E]) { return 2 }
        return seen0(b)
    }

    static func seen2(_ b: ArraySlice<UInt8>) -> Int? {
        guard let f = b.first else { return nil }
        if f == 0x3E { return 1 }
        return seen1(b)
    }
}

/// `DtdParser`: the `>` that ends a DOCTYPE, skipping quoted literals and the internal subset. Every caller here
/// feeds the whole rest of the input as one chunk, so the state that waits for a second chunk (`UndecidedMarkup`)
/// ends the search.
struct DTDParser: Sendable {
    enum State: Sendable {
        case beforeInternalSubset(UInt8)
        case insideOfInternalSubset
        case afterInternalSubset
        case inComment(CommentParserBox)
        case inPI(Bool)
        case inElementDecl
        case inQuoteSensitive(ElementParserBox)
        case undecidedMarkup
        case finished
    }

    /// Sendable wrappers for the nested parsers' states.
    struct CommentParserBox: Sendable { var p: CommentParser }
    struct ElementParserBox: Sendable { var p: ElementParser }

    var state = State.beforeInternalSubset(0)

    var finished: Bool {
        if case .finished = state { return true }
        return false
    }

    mutating func feed(_ chunk: ArraySlice<UInt8>) -> Int? {
        let s0 = chunk.startIndex
        var cur = chunk
        while !cur.isEmpty {
            switch state {
            case .beforeInternalSubset(0):
                guard let i = cur.firstIndex(where: { $0 == 0x27 || $0 == 0x22 || $0 == 0x5B || $0 == 0x3E }) else { return nil }
                switch cur[i] { // never-crash: i from a search
                case 0x27, 0x22:
                    state = .beforeInternalSubset(cur[i]) // never-crash: as above
                    cur = cur[(i + 1)...] // never-crash: i < endIndex
                case 0x5B:
                    state = .insideOfInternalSubset
                    cur = cur[(i + 1)...] // never-crash: i < endIndex
                default:
                    state = .finished
                    return i - s0
                }
            case .beforeInternalSubset(let q):
                guard let i = cur.firstIndex(of: q) else { return nil }
                state = .beforeInternalSubset(0)
                cur = cur[(i + 1)...] // never-crash: i < endIndex
            case .insideOfInternalSubset:
                guard let i = cur.firstIndex(where: { $0 == 0x5D || $0 == 0x3C }) else { return nil }
                if cur[i] == 0x5D { // never-crash: i from a search
                    state = .afterInternalSubset
                    cur = cur[(i + 1)...] // never-crash: i < endIndex
                    continue
                }
                let markup = cur[(i + 1)...] // never-crash: i < endIndex
                if let skip = switchMarkup(markup) {
                    cur = cur[(i + 1 + skip)...] // never-crash: skip <= markup.count
                    continue
                }
                let skipped = cur.endIndex - i - 1
                if skipped >= 9 {
                    cur = cur[(i + 1)...] // never-crash: i < endIndex
                    state = .inElementDecl
                    continue
                }
                state = .undecidedMarkup
                return nil
            case .afterInternalSubset:
                guard let i = cur.firstIndex(of: 0x3E) else { return nil }
                state = .finished
                return i - s0
            case .inComment(var box):
                if let i = box.p.feed(cur) {
                    state = .insideOfInternalSubset
                    cur = cur[(cur.startIndex + i)...] // never-crash: i <= count
                    continue
                }
                state = .inComment(box)
                return nil
            case .inPI(let seen):
                var p = PIParser(seenQuestion: seen)
                if let i = p.feed(cur) {
                    state = .insideOfInternalSubset
                    cur = cur[(cur.startIndex + i)...] // never-crash: i < count
                    continue
                }
                state = .inPI(p.seenQuestion)
                return nil
            case .inElementDecl:
                guard let i = cur.firstIndex(of: 0x3E) else { return nil }
                state = .insideOfInternalSubset
                cur = cur[(i + 1)...] // never-crash: i < endIndex
            case .inQuoteSensitive(var box):
                if let i = box.p.feed(cur) {
                    state = .insideOfInternalSubset
                    cur = cur[(cur.startIndex + i)...] // never-crash: i < count
                    continue
                }
                state = .inQuoteSensitive(box)
                return nil
            case .undecidedMarkup, .finished:
                return nil
            }
        }
        return nil
    }

    /// `switch`: the markup after a `<` in the internal subset.
    mutating func switchMarkup(_ m: ArraySlice<UInt8>) -> Int? {
        if m.first == 0x3F {
            state = .inPI(false)
            return 1
        }
        if m.starts(with: "!--".utf8) {
            state = .inComment(CommentParserBox(p: .seen0))
            return 3
        }
        if m.starts(with: "!ELEMENT".utf8) {
            state = .inElementDecl
            return 8
        }
        if m.starts(with: "!ENTITY".utf8) {
            state = .inQuoteSensitive(ElementParserBox(p: .outside))
            return 7
        }
        if m.starts(with: "!ATTLIST".utf8) {
            state = .inQuoteSensitive(ElementParserBox(p: .outside))
            return 8
        }
        if m.starts(with: "!NOTATION".utf8) {
            state = .inQuoteSensitive(ElementParserBox(p: .outside))
            return 9
        }
        if let i = m.firstIndex(of: 0x3E) {
            state = .insideOfInternalSubset
            return i - m.startIndex + 1
        }
        return nil
    }
}

/// `BangType`: which `<!…>` construct is being read.
enum BangType: Sendable {
    case cdata
    case comment
    case docType(DTDParser)

    /// `feed` over the whole rest of the input (from `<!`): the index of the closing `>`.
    mutating func feed(_ chunk: ArraySlice<UInt8>) -> Int? {
        let s = chunk.startIndex
        switch self {
        case .comment:
            for i in chunk.indices where chunk[i] == 0x3E { // never-crash: i in indices
                let k = i - s
                if k > 5, chunk[i - 1] == 0x2D, chunk[i - 2] == 0x2D { return k } // never-crash: k > 5
            }
            return nil
        case .cdata:
            for i in chunk.indices where chunk[i] == 0x3E { // never-crash: i in indices
                if i - s >= 2, chunk[i - 1] == 0x5D, chunk[i - 2] == 0x5D { return i - s } // never-crash: checked
            }
            return nil
        case .docType(var p):
            let r = p.feed(chunk)
            self = .docType(p)
            return r
        }
    }

    var eofError: XMLSyntaxError {
        switch self {
        case .cdata: .unclosedCData
        case .comment: .unclosedComment
        case .docType: .unclosedDoctype
        }
    }
}
