// CNXML — the event writer: a port of quick-xml 0.41.0's `Writer` (src/writer.rs; MIT, © Johann Tuffe and the
// quick-xml contributors) without indentation, which is how `Writer::new` writes. Every event goes out as the bytes
// it holds, between its markup: a read event written back is the input byte for byte, except a DOCTYPE (written as
// `<!DOCTYPE ` plus its name and the rest, so leading whitespace is one space) and an end tag whose name the reader
// trimmed.

public struct XMLWriter: Sendable {
    public private(set) var output: [UInt8] = []
    /// `add_space_before_slash_in_empty_elements`: `<a />` instead of `<a/>`.
    public var addSpaceBeforeSlashInEmptyElements = false

    public init() {}

    /// `write_event`.
    public mutating func writeEvent(_ event: XMLEvent) {
        switch event {
        case .start(let e): wrapped("<", e.buf, ">")
        case .end(let e): wrapped("</", e.nameBytes, ">")
        case .empty(let e): wrapped("<", e.buf, addSpaceBeforeSlashInEmptyElements ? " />" : "/>")
        case .text(let t): output.append(contentsOf: t.content)
        case .comment(let t): wrapped("<!--", t.content, "-->")
        case .cdata(let t): wrapped("<![CDATA[", t.content, "]]>")
        case .decl(let d): wrapped("<?", d.start.buf, "?>")
        case .pi(let p): wrapped("<?", p.content, "?>")
        case .docType(let t): wrapped("<!DOCTYPE ", t.content, ">")
        case .generalRef(let t): wrapped("&", t.content, ";")
        case .eof: break
        }
    }

    /// `write_bom`.
    public mutating func writeBOM() { output.append(contentsOf: [0xEF, 0xBB, 0xBF]) }

    /// Raw bytes, as `get_mut().write_all` would add them.
    public mutating func writeRaw(_ bytes: some Sequence<UInt8>) { output.append(contentsOf: bytes) }

    mutating func wrapped(_ before: String, _ value: ArraySlice<UInt8>, _ after: String) {
        output.append(contentsOf: before.utf8)
        output.append(contentsOf: value)
        output.append(contentsOf: after.utf8)
    }

    /// `into_inner`.
    public func intoInner() -> [UInt8] { output }
}
