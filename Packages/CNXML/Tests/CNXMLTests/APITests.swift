// CNXML's API as GCXLSX uses it, on small documents. The byte-for-byte checks against quick-xml are VectorTests.
import Testing
@testable import CNXML

@Suite struct APITests {
    func events(_ s: String, _ configure: (inout XMLReaderConfig) -> Void = { _ in }) -> [XMLEvent] {
        var r = XMLReader(s)
        configure(&r.config)
        var out: [XMLEvent] = []
        while let e = try? r.readEvent() {
            out.append(e)
            if case .eof = e { break }
        }
        return out
    }

    @Test func startTagsAndAttributes() throws {
        var r = XMLReader(#"<x:a k="1&amp;2" y='b'>t</x:a>"#)
        guard case .start(let e) = try r.readEvent() else {
            Issue.record("expected a start tag")
            return
        }
        #expect(Array(e.name.bytes) == Array("x:a".utf8))
        #expect(Array(e.localName) == Array("a".utf8))
        let attrs = e.attributes().compactMap { try? $0.get() }
        #expect(attrs.count == 2)
        #expect(try attrs[0].normalizedValue(.explicit1_0) == "1&2")
        #expect(try e.tryGetAttribute("y".utf8).map { Array($0.value) } == Array("b".utf8))
        #expect(try e.tryGetAttribute("z".utf8) == nil)
        guard case .text(let t) = try r.readEvent() else {
            Issue.record("expected text")
            return
        }
        #expect(try t.xmlContent(.explicit1_0) == "t")
        guard case .end(let end) = try r.readEvent() else {
            Issue.record("expected an end tag")
            return
        }
        #expect(Array(end.localName) == Array("a".utf8))
        #expect(try r.readEvent() == .eof)
        #expect(try r.readEvent() == .eof)
    }

    @Test func positionsSliceTheInput() throws {
        var r = XMLReader("<r><p>abc</p><q/></r>")
        _ = try r.readEvent()
        let start = r.bufferPosition
        guard case .start(let p) = try r.readEvent() else {
            Issue.record("expected <p>")
            return
        }
        let span = try r.readToEnd(p.name.bytes)
        #expect(start == 3)
        #expect(span == 6 ..< 9)
        #expect(Array(r.input[(r.inputStart + start) ..< (r.inputStart + r.bufferPosition)]) == Array("<p>abc</p>".utf8))
    }

    @Test func bomIsRemovedAndNotCounted() throws {
        var r = XMLReader([0xEF, 0xBB, 0xBF] + Array("<r/>".utf8))
        guard case .empty = try r.readEvent() else {
            Issue.record("expected <r/>")
            return
        }
        #expect(r.bufferPosition == 4)
        #expect(r.inputStart == 3)
    }

    @Test func errorsStopOrContinue() throws {
        var r = XMLReader("<a><!x></a>")
        _ = try? r.readEvent()
        #expect(throws: XMLError.syntax(.invalidBangMarkup)) { try r.readEvent() }
        #expect(try r.readEvent() == .eof)

        var s = XMLReader("<a></b><c/>")
        _ = try? s.readEvent()
        #expect(throws: XMLError.illFormed(.mismatchedEndTag(expected: "a", found: "b"))) { try s.readEvent() }
        #expect(throws: Never.self) { try s.readEvent() }
        #expect("\(XMLError.illFormed(.mismatchedEndTag(expected: "a", found: "b")))" == "ill-formed document: expected `</a>`, but `</b>` was found")
    }

    @Test func danglingAmpersand() {
        let evs = events("<r>a & b</r>") { $0.allowDanglingAmp = true }
        let texts = evs.compactMap { e -> String? in if case .text(let t) = e { return try? t.decode() } else { return nil } }
        #expect(texts == ["a ", "& b"])
    }

    @Test func namespaces() throws {
        var r = XMLNSReader(#"<a xmlns="u" xmlns:p="v"><p:b p:x="1" y="2"/><c/></a>"#)
        _ = try r.readEvent()
        guard case .empty(let b) = try r.readEvent() else {
            Issue.record("expected <p:b/>")
            return
        }
        #expect(r.resolver.resolveElement(b.name).0 == .bound(Array("v".utf8)))
        let attrs = b.attributes().compactMap { try? $0.get() }
        #expect(r.resolver.resolveAttribute(attrs[0].key).0 == .bound(Array("v".utf8)))
        #expect(r.resolver.resolveAttribute(attrs[1].key).0 == .unbound)
        guard case .empty(let c) = try r.readEvent() else {
            Issue.record("expected <c/>")
            return
        }
        #expect(r.resolver.resolveElement(c.name).0 == .bound(Array("u".utf8)))
        #expect(r.resolver.resolveElement(XMLQName("q:z")).0 == .unknown(Array("q".utf8)))
    }

    @Test func writerRebuildsStartTags() {
        var w = XMLWriter()
        var e = XMLStart(name: "a")
        e.pushAttribute("k", "<&\">")
        e.pushAttribute(XMLAttribute(key: XMLQName("r:id"), value: Array("rId1".utf8)[...]))
        w.writeEvent(.start(e))
        w.writeEvent(.text(XMLText("x<y")))
        w.writeEvent(.end(e.toEnd))
        w.writeEvent(.empty(XMLStart(name: "b")))
        #expect(String(decoding: w.output, as: UTF8.self) == #"<a k="&lt;&amp;&quot;&gt;" r:id="rId1">x&lt;y</a><b/>"#)
    }

    @Test func rustUTF8Errors() {
        #expect(RustUTF8Error.check(Array("ok é".utf8)) == nil)
        #expect(RustUTF8Error.check([0x61, 0xFF]) == RustUTF8Error(validUpTo: 1, errorLen: 1))
        #expect(RustUTF8Error.check([0xE2, 0x82]) == RustUTF8Error(validUpTo: 0, errorLen: nil))
        #expect(RustUTF8Error.check([0xE2, 0x82, 0x41]) == RustUTF8Error(validUpTo: 0, errorLen: 2))
        #expect(RustUTF8Error.check([0xF0, 0x9F, 0x98, 0x41]) == RustUTF8Error(validUpTo: 0, errorLen: 3))
        #expect(RustUTF8Error.check([0xED, 0xA0, 0x80]) == RustUTF8Error(validUpTo: 0, errorLen: 1))
    }

    /// Hostile sizes stay linear: a long run of `<` and `&` reads in bounded time without growing the stack.
    @Test func hostileInputIsLinear() {
        let doc = [UInt8](repeating: 0x3C, count: 200_000) + [UInt8](repeating: 0x26, count: 200_000)
        for mode in [false, true] {
            var r = XMLReader(doc)
            r.config.allowDanglingAmp = mode
            var n = 0
            while n < 1_000_000, let e = try? r.readEvent() {
                n += 1
                if case .eof = e { break }
            }
            #expect(n < 1_000_000)
        }
        let deep = String(repeating: "<a>", count: 100_000)
        var r = XMLReader(deep)
        var n = 0
        while let e = try? r.readEvent(), e != .eof { n += 1 }
        #expect(n == 100_000)
    }
}
