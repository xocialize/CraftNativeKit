// CNXML — namespaces: a port of quick-xml 0.41.0's `NamespaceResolver` (src/name.rs) and `NsReader`
// (src/reader/ns_reader.rs) over a byte slice (MIT, © Johann Tuffe and the quick-xml contributors).

/// `ResolveResult`: what a prefix (or the default namespace) is bound to.
public enum XMLResolveResult: Sendable, Equatable {
    /// No prefix and no default namespace (or an attribute without a prefix).
    case unbound
    case bound([UInt8])
    /// A prefix with no binding in scope (or one reset with `xmlns:p=""`).
    case unknown([UInt8])

    public func isBound(to ns: some Collection<UInt8>) -> Bool {
        if case .bound(let b) = self { return b.elementsEqual(ns) }
        return false
    }
}

/// `NamespaceResolver`: the bindings in scope, innermost last.
public struct XMLNamespaceResolver: Sendable {
    struct Binding: Sendable {
        var start: Int
        var prefixLen: Int
        var valueLen: Int
        var level: UInt16
    }

    static let xmlPrefix = Array("xml".utf8)
    static let xmlNamespace = Array("http://www.w3.org/XML/1998/namespace".utf8)
    static let xmlnsPrefix = Array("xmlns".utf8)
    static let xmlnsNamespace = Array("http://www.w3.org/2000/xmlns/".utf8)

    var buffer: [UInt8] = []
    var bindings: [Binding] = []
    public private(set) var level: UInt16 = 0
    /// `max_declarations_per_element` (quick-xml's default, 256).
    public var maxDeclarationsPerElement = 256

    public init() {
        for (p, ns) in [(Self.xmlPrefix, Self.xmlNamespace), (Self.xmlnsPrefix, Self.xmlnsNamespace)] {
            bindings.append(Binding(start: buffer.count, prefixLen: p.count, valueLen: ns.count, level: 0))
            buffer += p
            buffer += ns
        }
    }

    func prefix(of b: Binding) -> ArraySlice<UInt8>? {
        guard b.prefixLen > 0 else { return nil }
        return buffer[b.start ..< (b.start + b.prefixLen)] // never-crash: bindings index buffer
    }

    func namespace(of b: Binding) -> XMLResolveResult {
        guard b.valueLen > 0 else { return .unbound }
        let s = b.start + b.prefixLen
        return .bound(Array(buffer[s ..< (s + b.valueLen)])) // never-crash: bindings index buffer
    }

    /// `add`: binds `prefix` (nil for the default namespace) to `namespace` at the current level.
    public mutating func add(prefix: ArraySlice<UInt8>?, namespace: ArraySlice<UInt8>) throws(XMLNamespaceError) {
        guard let prefix else {
            bindings.append(Binding(start: buffer.count, prefixLen: 0, valueLen: namespace.count, level: level))
            buffer += namespace
            return
        }
        if prefix.elementsEqual(Self.xmlPrefix) {
            guard namespace.elementsEqual(Self.xmlNamespace) else { throw .invalidXmlPrefixBind(Array(namespace)) }
            return
        }
        if prefix.elementsEqual(Self.xmlnsPrefix) { throw .invalidXmlnsPrefixBind(Array(namespace)) }
        if namespace.elementsEqual(Self.xmlNamespace) { throw .invalidPrefixForXml(Array(prefix)) }
        if namespace.elementsEqual(Self.xmlnsNamespace) { throw .invalidPrefixForXmlns(Array(prefix)) }
        bindings.append(Binding(start: buffer.count, prefixLen: prefix.count, valueLen: namespace.count, level: level))
        buffer += prefix
        buffer += namespace
    }

    /// `push`: a new level, with the `xmlns` and `xmlns:p` attributes of `start` (up to the first attribute that
    /// doesn't parse).
    public mutating func push(_ start: XMLStart) throws(XMLNamespaceError) {
        level &+= 1
        var count = 0
        for a in start.attributes().withChecks(false) {
            guard case .success(let attr) = a else { break }
            guard let binding = attr.key.namespaceBinding else { continue }
            if count >= maxDeclarationsPerElement { throw .tooManyDeclarations(maxDeclarationsPerElement) }
            count += 1
            try add(prefix: binding, namespace: attr.value)
        }
    }

    /// `pop`: back one level, dropping that level's bindings.
    public mutating func pop() { setLevel(level == 0 ? 0 : level - 1) }

    public mutating func setLevel(_ l: UInt16) {
        level = l
        guard let last = bindings.lastIndex(where: { $0.level <= l }) else {
            buffer.removeAll()
            bindings.removeAll()
            return
        }
        if last + 1 < bindings.count {
            let len = bindings[last + 1].start // never-crash: checked
            buffer.removeSubrange(Swift.min(len, buffer.count)...)
            bindings.removeSubrange((last + 1)...)
        }
    }

    /// `resolve_prefix`.
    public func resolvePrefix(_ prefix: ArraySlice<UInt8>?, useDefault: Bool) -> XMLResolveResult {
        switch (prefix, useDefault) {
        case (nil, false): return .unbound
        case (nil, true):
            guard let b = bindings.last(where: { $0.prefixLen == 0 }) else { return .unbound }
            return namespace(of: b)
        case (let p?, _):
            if let b = bindings.last(where: { self.prefix(of: $0).map { $0.elementsEqual(p) } ?? false }), b.valueLen != 0 {
                return namespace(of: b)
            }
            return .unknown(Array(p))
        }
    }

    /// `resolve_element`: an element's namespace (the default one when it has no prefix) and local name.
    public func resolveElement(_ name: XMLQName) -> (XMLResolveResult, ArraySlice<UInt8>) {
        (resolvePrefix(name.prefix, useDefault: true), name.localName)
    }

    /// `resolve_attribute`: an attribute's namespace (none without a prefix) and local name.
    public func resolveAttribute(_ name: XMLQName) -> (XMLResolveResult, ArraySlice<UInt8>) {
        (resolvePrefix(name.prefix, useDefault: false), name.localName)
    }
}

/// `NsReader<&[u8]>`: a reader that keeps the namespace bindings in scope as it goes.
public struct XMLNSReader: Sendable {
    public var reader: XMLReader
    public var resolver = XMLNamespaceResolver()
    var pendingPop = false

    public init(_ bytes: [UInt8]) { reader = XMLReader(bytes) }
    public init(_ bytes: ArraySlice<UInt8>) { reader = XMLReader(bytes) }
    public init(_ text: String) { reader = XMLReader(text) }

    public var config: XMLReaderConfig {
        get { reader.config }
        set { reader.config = newValue }
    }

    public var bufferPosition: Int { reader.bufferPosition }
    public var errorPosition: Int { reader.errorPosition }

    /// `read_event`: the next event; a start tag's bindings are in scope until its end tag has been returned.
    public mutating func readEvent() throws(XMLError) -> XMLEvent {
        if pendingPop {
            resolver.pop()
            pendingPop = false
        }
        let event = try reader.readEvent()
        switch event {
        case .start(let e):
            do { try resolver.push(e) } catch { throw .namespace(error) }
        case .empty(let e):
            do { try resolver.push(e) } catch { throw .namespace(error) }
            pendingPop = true
        case .end:
            pendingPop = true
        default: break
        }
        return event
    }

    /// `read_to_end`: as the plain reader's, then the start tag's scope is dropped.
    public mutating func readToEnd(_ end: some Collection<UInt8>) throws(XMLError) -> Range<Int> {
        let r = try reader.readToEnd(end)
        resolver.pop()
        return r
    }
}
