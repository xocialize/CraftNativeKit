// CNXML — attributes: a port of quick-xml 0.41.0's src/events/attributes.rs (MIT, © Johann Tuffe and the quick-xml
// contributors), XML rules only (no `html_attributes`). Error positions are offsets in the start tag's content.

/// `Attribute`: a key and its value as written (not unescaped).
public struct XMLAttribute: Sendable, Equatable {
    public var key: XMLQName
    public var value: ArraySlice<UInt8>

    public init(key: XMLQName, value: ArraySlice<UInt8>) {
        self.key = key
        self.value = value
    }

    /// `(&str, &str)` into `Attribute`: the value escaped (`escape`).
    public init(_ key: String, _ value: String) {
        self.key = XMLQName(key)
        self.value = Array(XMLEscape.escape(value).utf8)[...]
    }

    /// `normalized_value`: the value as UTF-8, references resolved (the predefined entities) and whitespace
    /// normalised for `version` (XML §3.3.3).
    public func normalizedValue(_ version: XMLVersion) throws(XMLError) -> String {
        let decoded: String
        do { decoded = try decodeUTF8(value) } catch { throw .encoding(error) }
        do {
            return try XMLEscape.normalizeAttributeValue(decoded, version: version, depth: 1)
        } catch {
            throw .escape(error)
        }
    }

    /// `decoded_and_normalized_value`: without the `encoding` feature, the same as `normalizedValue`.
    public func decodedAndNormalizedValue(_ version: XMLVersion) throws(XMLError) -> String {
        try normalizedValue(version)
    }

    /// `unescape_value`: normalised as XML 1.0 without a declaration.
    public func unescapeValue() throws(XMLError) -> String { try normalizedValue(.implicit1_0) }

    /// `as_bool`.
    public var asBool: Bool? {
        if value.elementsEqual("1".utf8) || value.elementsEqual("true".utf8) { return true }
        if value.elementsEqual("0".utf8) || value.elementsEqual("false".utf8) { return false }
        return nil
    }

    public static func == (a: XMLAttribute, b: XMLAttribute) -> Bool { a.key == b.key && a.value.elementsEqual(b.value) }
}

/// `Attributes`: an iterator over a start tag's attributes. Each step is an attribute or the error that stopped
/// it; iteration recovers after an error the way quick-xml's does. `flatten` in Rust keeps only the attributes,
/// which `compactMap { try? $0.get() }` does here.
public struct XMLAttributes: Sequence, IteratorProtocol, Sendable {
    enum State: Sendable {
        case done
        case next(Int)
        case skipValue(Int)
        case skipEqValue(Int)
    }

    /// The tag's content (a slice of the reader's input); positions are offsets from its start.
    let buf: ArraySlice<UInt8>
    let base: Int
    let n: Int
    var state: State
    var checkDuplicates = true
    /// Keys accepted so far (ranges in `bytes`), for the duplicate check.
    var keys: [Range<Int>] = []
    /// From 32 keys on: each name → the first position it was declared at (quick-xml's hashed check, which finds
    /// the same previous declaration).
    var keyIndex: [[UInt8]: Int]?

    init(_ buf: ArraySlice<UInt8>, offset: Int) {
        self.buf = buf
        base = buf.startIndex
        n = buf.count
        state = .next(offset)
    }

    /// `with_checks`: whether a duplicated key is an error.
    public func withChecks(_ on: Bool) -> XMLAttributes {
        var a = self
        a.checkDuplicates = on
        return a
    }

    @inline(__always) static func ws(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0D || b == 0x0A || b == 0x09 }

    /// The byte at offset `i` (callers keep `i < n`).
    @inline(__always) func at(_ i: Int) -> UInt8 { buf[base + i] } // never-crash: callers check i < n

    @inline(__always) func slice(_ r: Range<Int>) -> ArraySlice<UInt8> { buf[(base + r.lowerBound) ..< (base + r.upperBound)] } // never-crash: ranges within 0...n

    func recover() -> Int? {
        switch state {
        case .done: nil
        case .next(let o): o
        case .skipValue(let o): skipValue(o)
        case .skipEqValue(let o): skipEqValue(o)
        }
    }

    func skipValue(_ offset: Int) -> Int? {
        var i = offset
        while i < n {
            if Self.ws(at(i)) { return i }
            i += 1
        }
        return nil
    }

    func skipEqValue(_ offset: Int) -> Int? {
        var i = offset
        while i < n, Self.ws(at(i)) { i += 1 }
        guard i < n else { return nil }
        let q = at(i)
        guard q == 0x22 || q == 0x27 else { return skipValue(i) }
        i += 1
        while i < n {
            if at(i) == q { return i }
            i += 1
        }
        return nil
    }

    mutating func checkForDuplicates(_ key: Range<Int>) -> XMLAttrError? {
        guard checkDuplicates else { return nil }
        let k = slice(key)
        if keys.count >= 32 {
            if keyIndex == nil {
                var d: [[UInt8]: Int] = [:]
                for r in keys where d[Array(slice(r))] == nil { d[Array(slice(r))] = r.lowerBound }
                keyIndex = d
            }
            if let prev = keyIndex?[Array(k)] { return .duplicated(key.lowerBound, prev) }
            keyIndex?[Array(k)] = key.lowerBound
            keys.append(key)
            return nil
        }
        if let prev = keys.first(where: { slice($0).elementsEqual(k) }) {
            return .duplicated(key.lowerBound, prev.lowerBound)
        }
        keys.append(key)
        return nil
    }

    func attribute(_ key: Range<Int>, _ value: Range<Int>) -> XMLAttribute {
        XMLAttribute(key: XMLQName(slice(key)), value: slice(value))
    }

    public mutating func next() -> Result<XMLAttribute, XMLAttrError>? {
        guard let offset = recover() else { return nil }
        var i = offset
        // The next key starts at the first non-whitespace byte.
        while i < n, Self.ws(at(i)) { i += 1 }
        guard i < n else {
            state = .done
            return nil
        }
        let startKey = i
        i += 1
        // The key runs to `=` or whitespace.
        while i < n, at(i) != 0x3D, !Self.ws(at(i)) { i += 1 }
        guard i < n else {
            state = .done
            return .failure(.expectedEq(n))
        }
        let e = i
        var eqAt: Int
        if at(i) == 0x3D {
            eqAt = e
            i += 1
        } else {
            i += 1
            while i < n, Self.ws(at(i)) { i += 1 }
            guard i < n else {
                state = .done
                return .failure(.expectedEq(n))
            }
            guard at(i) == 0x3D else {
                state = .next(i)
                return .failure(.expectedEq(i))
            }
            eqAt = i
            i += 1
        }
        let key = startKey ..< e
        if let err = checkForDuplicates(key) {
            state = .skipEqValue(eqAt)
            return .failure(err)
        }
        while i < n, Self.ws(at(i)) { i += 1 }
        guard i < n else {
            state = .done
            return .failure(.expectedValue(n))
        }
        let q = at(i)
        guard q == 0x22 || q == 0x27 else {
            state = .skipValue(i)
            return .failure(.unquotedValue(i))
        }
        let startValue = i + 1
        var j = startValue
        while j < n, at(j) != q { j += 1 }
        guard j < n else {
            state = .done
            return .failure(.expectedQuote(n, q))
        }
        state = .next(j + 1)
        _ = eqAt
        return .success(attribute(key, startValue ..< j))
    }
}
