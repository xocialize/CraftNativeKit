// CNXML against quick-xml 0.41.0 itself: GridCraftNative's `Tools/oracle/oracle.sh xml-vectors` runs the pinned crate
// over the oracle corpus's XML parts and generated hostile documents and writes what it saw in six reader
// configurations (xml-vectors/src/main.rs there). This file prints the same lines from CNXML and compares them.
//
// The vectors are found at `CNXML_VECTORS` (a `xml/<pin>` folder), else in GridCraftNative's fixtures
// (`GRIDCRAFT_FIXTURES`, default `../GridCraftNative-Fixtures`) at the pin GridCraftNative's `pin.env` names, else
// the first pin there. Without them the tests say so and pass.
import Foundation
import Testing
@testable import CNXML

enum XMLVectors {
    static var dir: URL? {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        if let v = env["CNXML_VECTORS"], !v.isEmpty { return URL(filePath: v, directoryHint: .isDirectory) }
        let research = repositoryRoot.deletingLastPathComponent()
        let fixtures = env["GRIDCRAFT_FIXTURES"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? research.appending(path: "GridCraftNative-Fixtures", directoryHint: .isDirectory)
        let xml = fixtures.appending(path: "xml", directoryHint: .isDirectory)
        let pinFile = research.appending(path: "GridCraftNative/Tools/oracle/pin.env")
        if let text = try? String(contentsOf: pinFile, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("GRIDCRAFT_PIN=") }) {
            let pin = String(line.dropFirst("GRIDCRAFT_PIN=".count).prefix(8))
            let d = xml.appending(path: pin, directoryHint: .isDirectory)
            if fm.fileExists(atPath: d.appending(path: "default.out").path) { return d }
        }
        guard let first = (try? fm.contentsOfDirectory(atPath: xml.path))?.sorted().first else { return nil }
        let d = xml.appending(path: first, directoryHint: .isDirectory)
        return fm.fileExists(atPath: d.appending(path: "default.out").path) ? d : nil
    }

    static var repositoryRoot: URL {
        // …/Packages/CNXML/Tests/CNXMLTests/VectorTests.swift
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

enum Mode: String, CaseIterable, Sendable {
    case stream, deck, `default`, misc, skip, ns
}

/// main.rs's `esc`.
func esc(_ b: some Sequence<UInt8>) -> String {
    var s = ""
    for c in b {
        switch c {
        case 0x5C: s += "\\\\"
        case 0x20 ... 0x7E: s.unicodeScalars.append(Unicode.Scalar(c))
        default:
            s += "\\x"
            if c < 16 { s += "0" }
            s += String(c, radix: 16)
        }
    }
    return s
}

func esc(_ s: String) -> String { esc(s.utf8) }

func res<E: Error>(_ body: () throws(E) -> String) -> String {
    do { return "ok:" + esc(try body()) } catch { return "err:" + esc("\(error)") }
}

func resolved(_ r: XMLResolveResult) -> String {
    switch r {
    case .unbound: "U"
    case .bound(let ns): "B:" + esc(ns)
    case .unknown(let p): "K:" + esc(p)
    }
}

let maxEvents = 200_000
let maxAttrs = 10_000

func attrLines(_ e: XMLStart, _ out: inout [String]) {
    var n = 0
    for a in e.attributes().withChecks(false) {
        if n >= maxAttrs { break }
        n += 1
        switch a {
        case .success(let a):
            let prefix = a.key.prefix.map { esc($0) } ?? "-"
            out.append("a\tok\t\(esc(a.key.bytes))\t\(esc(a.value))\t\(res { () throws(XMLError) in try a.normalizedValue(.explicit1_0) })\t\(res { () throws(XMLError) in try a.normalizedValue(.explicit1_1) })\t\(esc(a.key.localName))\t\(prefix)")
        case .failure(let err): out.append("a\terr\t\(esc("\(err)"))")
        }
    }
    n = 0
    for a in e.attributes() {
        if n >= maxAttrs { break }
        n += 1
        switch a {
        case .success(let a): out.append("c\tok\t\(esc(a.key.bytes))")
        case .failure(let err): out.append("c\terr\t\(esc("\(err)"))")
        }
    }
}

func eventFields(_ ev: XMLEvent) -> String {
    switch ev {
    case .start(let e): "S\t\(esc(e.buf))\t\(e.name.bytes.count)\t\(esc(e.localName))"
    case .empty(let e): "M\t\(esc(e.buf))\t\(e.name.bytes.count)\t\(esc(e.localName))"
    case .end(let e): "N\t\(esc(e.nameBytes))\t\(esc(e.localName))"
    case .text(let t):
        "T\t\(esc(t.content))\t\(res { () throws(XMLEncodingError) in try t.xmlContent(.explicit1_0) })\t\(res { () throws(XMLEncodingError) in try t.xmlContent(.explicit1_1) })\t\(res { () throws(XMLEncodingError) in try t.decode() })"
    case .cdata(let t):
        "D\t\(esc(t.content))\t\(res { () throws(XMLEncodingError) in try t.decode() })\t\(res { () throws(XMLEncodingError) in try t.xmlContent(.explicit1_0) })"
    case .comment(let t): "C\t\(esc(t.content))"
    case .decl(let d): "L\t\(esc(d.content))"
    case .pi(let p): "P\t\(esc(p.content))\t\(esc(p.target))"
    case .docType(let t): "Y\t\(esc(t.content))"
    case .generalRef(let r):
        "R\t\(esc(r.content))\t" + {
            do {
                if let c = try r.resolveCharRef() { return "ok:U+" + String(c.value, radix: 16, uppercase: true) }
                return "none"
            } catch {
                return "err:" + esc("\(error)")
            }
        }()
    case .eof: "F"
    }
}

func configure(_ c: inout XMLReaderConfig, _ mode: Mode) {
    switch mode {
    case .stream:
        c.checkEndNames = false
        c.allowUnmatchedEnds = true
        c.allowDanglingAmp = true
        c.trimTextStart = false
        c.trimTextEnd = false
    case .deck:
        c.trimText(false)
        c.checkEndNames = false
        c.allowUnmatchedEnds = true
        c.expandEmptyElements = false
    case .misc:
        c.expandEmptyElements = true
        c.trimText(true)
        c.checkComments = true
        c.trimMarkupNamesInClosingTags = false
    case .default, .skip, .ns: break
    }
}

func rebuild(_ e: XMLStart) -> XMLStart? {
    guard String(validating: e.name.bytes, as: UTF8.self) != nil else { return nil }
    var out = XMLStart(name: e.name.bytes)
    for a in e.attributes().withChecks(false) {
        guard case .success(let a) = a else { return nil }
        out.pushAttribute(XMLAttribute(key: a.key, value: a.value))
    }
    return out
}

func runReader(_ doc: [UInt8], _ mode: Mode, _ out: inout [String]) {
    var reader = XMLReader(doc)
    configure(&reader.config, mode)
    var writer = XMLWriter()
    var rebuilt = XMLWriter()
    var rebuiltOK = true, writtenOK = true
    for _ in 0 ..< maxEvents {
        let before = reader.bufferPosition
        let ev: XMLEvent
        do {
            ev = try reader.readEvent()
        } catch {
            out.append("\(before)\t\(reader.bufferPosition)\tX\t\(esc("\(error)"))\t\(reader.errorPosition)")
            writtenOK = false
            rebuiltOK = false
            continue
        }
        out.append("\(before)\t\(reader.bufferPosition)\t\(eventFields(ev))")
        if mode != .skip {
            switch ev {
            case .start(let e), .empty(let e): attrLines(e, &out)
            default: break
            }
        }
        if mode == .default {
            if case .text(let t) = ev, let s = try? t.decode() {
                out.append("t\t\(esc(XMLEscape.escape(s)))\t\(esc(XMLEscape.partialEscape(s)))\t\(esc(XMLEscape.minimalEscape(s)))\t\(res { () throws(XMLEscapeError) in try XMLEscape.unescape(s) })")
            }
            if writtenOK { writer.writeEvent(ev) }
            if rebuiltOK {
                let r: XMLEvent? = switch ev {
                case .start(let e): rebuild(e).map { .start($0) }
                case .empty(let e): rebuild(e).map { .empty($0) }
                default: ev
                }
                if let r { rebuilt.writeEvent(r) } else { rebuiltOK = false }
            }
        }
        if mode == .skip, case .start(let e) = ev {
            let name = Array(e.name.bytes)
            do {
                let span = try reader.readToEnd(name)
                out.append("K\t\(span.lowerBound)\t\(span.upperBound)\t\(reader.bufferPosition)")
            } catch {
                out.append("KX\t\(esc("\(error)"))\t\(reader.errorPosition)\t\(reader.bufferPosition)")
            }
        }
        if case .eof = ev { break }
    }
    if mode == .default {
        out.append("W\t\(esc(writer.output))\t\(writtenOK ? "ok" : "stopped")")
        out.append("B\t\(esc(rebuilt.output))\t\(rebuiltOK ? "ok" : "stopped")")
    }
}

func runNS(_ doc: [UInt8], _ out: inout [String]) {
    var reader = XMLNSReader(doc)
    for _ in 0 ..< maxEvents {
        let before = reader.bufferPosition
        let ev: XMLEvent
        do {
            ev = try reader.readEvent()
        } catch {
            out.append("\(before)\t\(reader.bufferPosition)\tX\t\(esc("\(error)"))\t\(reader.errorPosition)")
            continue
        }
        out.append("\(before)\t\(reader.bufferPosition)\t\(eventFields(ev))")
        switch ev {
        case .start(let e), .empty(let e):
            let (ns, local) = reader.resolver.resolveElement(e.name)
            out.append("n\t\(resolved(ns))\t\(esc(local))")
            var n = 0
            for a in e.attributes() {
                if n >= maxAttrs { break }
                n += 1
                switch a {
                case .success(let a):
                    let (ns, local) = reader.resolver.resolveAttribute(a.key)
                    out.append("na\t\(esc(a.key.bytes))\t\(resolved(ns))\t\(esc(local))")
                case .failure(let err): out.append("na\terr\t\(esc("\(err)"))")
                }
            }
        default: break
        }
        if case .eof = ev { break }
    }
}

@Suite struct VectorTests {
    @Test(arguments: Mode.allCases)
    func mode(_ mode: Mode) throws {
        guard let dir = XMLVectors.dir else {
            print("CNXML vectors not found: run GridCraftNative's Tools/oracle/oracle.sh xml-vectors (or set CNXML_VECTORS)")
            return
        }
        let expected = try String(contentsOf: dir.appending(path: "\(mode.rawValue).out"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        let inputs = dir.appending(path: "inputs", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: inputs.path).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var lines: [String] = []
        lines.reserveCapacity(expected.count)
        for name in names {
            let doc = try [UInt8](Data(contentsOf: inputs.appending(path: name)))
            var out: [String] = []
            if mode == .ns { runNS(doc, &out) } else { runReader(doc, mode, &out) }
            for l in out { lines.append(name + "\t" + l) }
        }
        var mismatches = 0
        for (i, (a, b)) in zip(lines, expected).enumerated() where !a.utf8.elementsEqual(b.utf8) {
            mismatches += 1
            if mismatches <= 10 { Issue.record("\(mode) line \(i + 1):\n  swift: \(a)\n  rust:  \(b)") }
        }
        #expect(lines.count == expected.count, "\(mode): \(lines.count) lines, the oracle has \(expected.count)")
        #expect(mismatches == 0, "\(mode): \(mismatches) of \(expected.count) lines differ")
        print("CNXML \(mode): \(expected.count) lines over \(names.count) documents, \(mismatches) differ")
    }
}
