// Parity with deckcraft-metafile: parses every file `Tools/oracle/metafile-vectors` wrote (the crate's own test
// shapes, more arcs, rotations, text, brushes, clips and bitmap formats, and mutations of each), places each
// picture, and compares the dump line for line with the oracle's, every float as its bit pattern. Skips cleanly
// without the fixtures.
@testable import CNMetafile
import CNTestSupport
import Foundation
import Testing

private let dir = Fixtures.root.appending(path: "metafile", directoryHint: .isDirectory)
private let dumpsURL = dir.appending(path: "dumps.txt")
private let haveVectors = FileManager.default.fileExists(atPath: dumpsURL.path)

private func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { $0 < 16 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
}

private func h64(_ v: Double) -> String {
    let s = String(v.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - s.count) + s
}

private func h32(_ v: Float) -> String {
    let s = String(v.bitPattern, radix: 16)
    return String(repeating: "0", count: 8 - s.count) + s
}

private func rgba(_ c: MetafileColor) -> String { hex([c[0], c[1], c[2], c[3]]) }

private func fnv(_ bytes: [UInt8]) -> String {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for x in bytes {
        h ^= UInt64(x)
        h = h &* 0x0000_0100_0000_01B3
    }
    let s = String(h, radix: 16)
    return String(repeating: "0", count: 16 - s.count) + s
}

private func segs(_ out: inout String, _ s: [MetafileSeg]) {
    for g in s {
        switch g {
        case .move(let x, let y): out += " M \(h32(x)) \(h32(y))\n"
        case .line(let x, let y): out += " L \(h32(x)) \(h32(y))\n"
        case .cubic(let a, let b, let c, let d, let e, let f): out += " C \(h32(a)) \(h32(b)) \(h32(c)) \(h32(d)) \(h32(e)) \(h32(f))\n"
        case .close: out += " Z\n"
        }
    }
}

private func region(_ r: [SIMD4<Float>]?) -> String {
    guard let v = r else { return "-" }
    var s = "\(v.count)"
    for q in v {
        for i in 0 ..< 4 { s += " " + h32(q[i]) }
    }
    return s
}

private func text(_ out: inout String, _ t: MetafileText) {
    let h = switch t.hAlign {
    case .left: "l"
    case .center: "c"
    case .right: "r"
    }
    let v = switch t.vAlign {
    case .top: "t"
    case .baseline: "b"
    case .bottom: "m"
    }
    let f = t.font
    let clip = t.clip.map { c in (0 ..< 4).map { h32(c[$0]) }.joined(separator: " ") } ?? "-"
    out += "text \(hex(t.text.utf8)) [\(t.transform.map(h64).joined(separator: " "))] dx [\(t.dx.map(h32).joined(separator: " "))] "
    out += "font \(hex(f.family.utf8)) \(h32(f.height)) \(h32(f.width)) \(f.weight) \(f.italic ? 1 : 0)\(f.underline ? 1 : 0)\(f.strike ? 1 : 0) "
    out += "\(f.charset) color \(rgba(t.color)) bg \(t.background.map(rgba) ?? "-") align \(h)\(v) clip \(clip) region \(region(t.region))\n"
}

private func affine(_ a: MetafileAffine) -> String { a.coeffs.map(h64).joined(separator: " ") }
private func rect(_ r: MetafileRect) -> String { "\(h64(r.x0)) \(h64(r.y0)) \(h64(r.x1)) \(h64(r.y1))" }

private func path(_ out: inout String, _ p: MetafilePath) {
    for e in p.elements {
        switch e {
        case .moveTo(let a): out += " M \(h64(a.x)) \(h64(a.y))\n"
        case .lineTo(let a): out += " L \(h64(a.x)) \(h64(a.y))\n"
        case .curveTo(let a, let b, let c): out += " C \(h64(a.x)) \(h64(a.y)) \(h64(b.x)) \(h64(b.y)) \(h64(c.x)) \(h64(c.y))\n"
        case .closePath: out += " Z\n"
        }
    }
}

private func placedRegion(_ out: inout String, _ r: MetafilePath?) {
    guard let p = r else {
        out += " region -\n"
        return
    }
    out += " region \(p.elements.count)\n"
    path(&out, p)
}

/// The dump `metafile-vectors` writes for one file.
func oracleDump(_ bytes: [UInt8]) -> String {
    var out = "is \(Metafile.isMetafile(bytes) ? 1 : 0)\n"
    var pic: MetafilePicture
    do {
        pic = try Metafile.parse(bytes)
    } catch {
        let name = switch error {
        case .notMetafile: "NotMetafile"
        case .badHeader: "BadHeader"
        case .noRecords: "NoRecords"
        }
        return out + "err \(name)\n"
    }
    out += "pic \(h32(pic.width)) \(h32(pic.height)) \(pic.items.count)\n"
    var tiles: [ObjectIdentifier: Int] = [:]
    for it in pic.items {
        switch it {
        case .path(let s, let fill, let stroke, let evenOdd, let r):
            let st = stroke.map { "\(rgba($0.color)) \(h32($0.width))" } ?? "-"
            out += "path \(s.count) fill \(fill.map(rgba) ?? "-") stroke \(st) eo \(evenOdd ? 1 : 0) region \(region(r))\n"
            segs(&out, s)
        case .bitmap(let rc, let w, let h, let px, let r):
            out += "bitmap [\((0 ..< 4).map { h32(rc[$0]) }.joined(separator: " "))] \(w) \(h) \(px.count) \(fnv(px)) region \(region(r))\n"
        case .pattern(let s, let evenOdd, let tile, let r):
            let key = ObjectIdentifier(tile)
            let id = tiles[key] ?? tiles.count
            tiles[key] = id
            out += "pattern \(s.count) eo \(evenOdd ? 1 : 0) tile \(id) \(tile.width) \(tile.height) \(fnv(tile.rgba)) "
            out += "cell \(h32(tile.cell[0])) \(h32(tile.cell[1])) origin \(h32(tile.origin[0])) \(h32(tile.origin[1])) region \(region(r))\n"
            segs(&out, s)
        case .text(let t):
            text(&out, t)
        }
    }
    let placed = pic.place(MetafileRect(10, 20, 410, 320), crop: SIMD4(0.05, 0.1, 0, 0.2))
    out += "placed \(placed.count)\n"
    for p in placed {
        switch p {
        case .path(let bp, let fill, let stroke, let evenOdd, let r):
            let st = stroke.map { "\(rgba($0.color)) \(h64($0.width))" } ?? "-"
            out += "ppath fill \(fill.map(rgba) ?? "-") stroke \(st) eo \(evenOdd ? 1 : 0)\n"
            path(&out, bp)
            placedRegion(&out, r)
        case .bitmap(let index, let rr, let r):
            out += "pbitmap \(index) \(rect(rr))\n"
            placedRegion(&out, r)
        case .pattern(let index, let bp, let evenOdd, let tile, let r):
            out += "ppattern \(index) eo \(evenOdd ? 1 : 0) tile \(affine(tile))\n"
            path(&out, bp)
            placedRegion(&out, r)
        case .text(let index, let transform, let clip, let r):
            out += "ptext \(index) \(affine(transform)) clip \(clip.map(rect) ?? "-")\n"
            placedRegion(&out, r)
        }
    }
    var taken: [String] = []
    for i in pic.items.indices {
        let t = pic.items[i].takePixels()
        taken.append(t.map { "\($0.width)x\($0.height):\(fnv($0.rgba))" } ?? "-")
    }
    out += "take \(taken.joined(separator: " "))\n"
    return out
}

@Test(.enabled(if: haveVectors, "needs \(dir.path) (Tools/oracle/metafile-vectors)"))
func metafileOracleParity() throws {
    let all = try String(contentsOf: dumpsURL, encoding: .utf8)
    var cases: [(String, String)] = []
    var name: String?
    var body = ""
    for line in all.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("== ") {
            if let n = name { cases.append((n, body)) }
            name = String(line.dropFirst(3))
            body = ""
        } else if name != nil, !line.isEmpty {
            body += line + "\n"
        }
    }
    if let n = name { cases.append((n, body)) }
    #expect(cases.count > 100)
    var mismatched: [String] = []
    for (n, expected) in cases {
        let data = try Data(contentsOf: dir.appending(path: "\(n).bin"))
        let got = oracleDump([UInt8](data))
        guard got != expected else { continue }
        mismatched.append(n)
        let (e, g) = (expected.split(separator: "\n"), got.split(separator: "\n"))
        let k = (0 ..< Swift.min(e.count, g.count)).first { e[$0] != g[$0] } ?? Swift.min(e.count, g.count)
        let want = k < e.count ? String(e[k]) : "<end>"
        let have = k < g.count ? String(g[k]) : "<end>"
        Issue.record("\(n): line \(k + 1)\n  oracle: \(want)\n  swift:  \(have)")
    }
    #expect(mismatched.isEmpty, "\(mismatched.count) of \(cases.count) cases differ")
}
