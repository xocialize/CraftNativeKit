// The tests that exist only in WordCraft's metafile crate (the five commits deckcraft never took), one Swift test per
// Rust test with the same name in camel case, plus the WordCraft text run and crop rule as CNMetafile carries them.
// Port of WordCraft crates/metafile/src/{canvas,dib,tests}.rs at fd7f6621 (MIT OR Apache-2.0, © ArtCraft Team and
// the WordCraft contributors).
import CNCore
@testable import CNMetafile
import Testing

/// WordCraft's test generator: xorshift64 from `seed`.
private struct XorShift {
    var seed: UInt64

    mutating func next() -> UInt64 {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return seed
    }

    mutating func callAsFunction(_ n: UInt64) -> UInt64 { next() % n }
}

// MARK: canvas.rs — the object table (45d2546b)

private func pen(_ id: UInt32) -> Obj {
    .pen(Pen(style: 0, width: 0, color: MetafileColor(UInt8(truncatingIfNeeded: id), UInt8(truncatingIfNeeded: id >> 8), 0, 255)))
}

private func idOf(_ o: Obj?) -> UInt32? {
    guard case .pen(let p)? = o else { return nil }
    return UInt32(p.color[0]) | UInt32(p.color[1]) << 8
}

/// The table as it was before the free-slot set: a scan from index 0 for every handle-table create.
private struct Naive {
    var slots: [UInt32?] = []

    mutating func add(_ slot: Int?, _ id: UInt32) {
        if let i = slot {
            guard i < Metafile.maxObjects else { return }
            if slots.count <= i { slots += [UInt32?](repeating: nil, count: i + 1 - slots.count) }
            slots[i] = id
        } else if let i = slots.firstIndex(where: { $0 == nil }) {
            slots[i] = id
        } else if slots.count < Metafile.maxObjects {
            slots.append(id)
        }
    }

    mutating func delete(_ i: UInt32) {
        if slots.indices.contains(Int(i)) { slots[Int(i)] = nil }
    }
}

@Test func handleTablePicksTheSameSlotsAsTheFirstFreeScan() {
    var rnd = XorShift(seed: 0x9E37_79B9_7F4A_7C15)
    for round in 0 ..< 20 {
        // Small tables exercise reuse; some rounds also run past the cap and use explicit EMF slots.
        let span: UInt64 = round % 2 == 0 ? 12 : UInt64(Metafile.maxObjects) + 50
        var (cv, naive) = (Canvas(), Naive())
        for id in UInt32(0) ..< 20_000 {
            switch rnd(10) {
            case 0 ... 4:
                cv.addObject(nil, pen(id))
                naive.add(nil, id)
            case 5, 6 where round >= 10:
                let slot = Int(rnd(span + 20))
                cv.addObject(slot, pen(id))
                naive.add(slot, id)
            default:
                let i = UInt32(rnd(span + 5))
                cv.deleteObject(i)
                naive.delete(i)
            }
            if id % 500 == 0 || id == 19_999 {
                let got = cv.objects.map(idOf)
                guard got == naive.slots else {
                    Issue.record("round \(round), step \(id)")
                    return
                }
            }
        }
    }
}

@Test func creatingIntoAFullTableDoesNotScanIt() {
    var cv = Canvas()
    for i in 0 ..< UInt32(Metafile.maxObjects) { cv.addObject(nil, pen(i)) }
    #expect(cv.objects.count == Metafile.maxObjects)
    let before = cv.slotProbes
    for i in UInt32(0) ..< 10_000 { cv.addObject(nil, pen(i)) }
    // A scan from index 0 would examine 4096 slots per create; the free set examines none.
    #expect(cv.slotProbes == before)
    cv.deleteObject(7)
    cv.addObject(nil, pen(99))
    #expect(cv.slotProbes == before + 1)
    #expect(idOf(cv.objects.at(7) ?? nil) == 99)
}

// MARK: dib.rs — cropped DIB decode (45d2546b)

/// A BITMAPINFOHEADER DIB with a palette for indexed depths; returns (info, bits).
private func makeDib(_ w: Int, _ h: Int32, _ bpp: Int, _ rnd: inout XorShift) -> ([UInt8], [UInt8]) {
    var info = h32(40) + e32(w) + h32(UInt32(bitPattern: h)) + u16b(1) + u16b(UInt16(bpp))
    info += [UInt8](repeating: 0, count: 24)
    if bpp <= 8 {
        for _ in 0 ..< (1 << bpp) * 4 { info.append(UInt8(truncatingIfNeeded: rnd.next())) }
    }
    let stride = (w * bpp + 31) / 32 * 4
    let bits = (0 ..< stride * Int(h.magnitude)).map { _ in UInt8(truncatingIfNeeded: rnd.next()) }
    return (info, bits)
}

@Test func decodeClipMatchesDecodeThenClipBlit() {
    var rnd = XorShift(seed: 0x2545_F491_4F6C_DD1D)
    var cases = 0
    for bpp in [1, 4, 8, 16, 24, 32] {
        for h: Int32 in [5, -5, 1, -1] {
            let (info, bits) = makeDib(7, h, bpp, &rnd)
            for keepAlpha in [false, true] {
                // Source x/y from outside the bitmap on both sides; sizes include zero and negative.
                for sx: Int64 in [-9, -2, 0, 3, 6, 8, 20] {
                    for sy: Int64 in [-9, -2, 0, 2, 4, 5, 20] {
                        for (sw, sh): (Int64, Int64) in [(0, 0), (-3, 4), (4, -2), (1, 1), (3, 2), (7, 5), (30, 30), (2, 9)] {
                            let src = [sx, sy, sw, sh]
                            let dst = R4(10, 20, 70, 50)
                            let old = DIB.decode(Bytes(info), Bytes(bits), keepAlpha: keepAlpha).flatMap { DIB.clipBlit($0, src, dst) }
                            let new = DIB.decodeClip(Bytes(info), Bytes(bits), keepAlpha: keepAlpha, src, dst)
                            switch (old, new) {
                            case (nil, nil):
                                break
                            case let ((a, ad)?, (b, bd)?):
                                #expect(a.w == b.w && a.h == b.h && a.px == b.px, "\(bpp) bpp h=\(h) \(src)")
                                #expect((0 ..< 4).allSatisfy { ad[$0].bitPattern == bd[$0].bitPattern }, "\(bpp) bpp h=\(h) \(src)")
                            default:
                                Issue.record("old and new disagree on nil: \(bpp) bpp h=\(h) \(src)")
                            }
                            cases += 1
                        }
                    }
                }
            }
        }
    }
    #expect(cases > 10_000)
}

@Test func decodeClipRejectsWhatDecodeRejected() {
    var rnd = XorShift(seed: 7)
    let (info, bits) = makeDib(7, 5, 24, &rnd)
    let short = Array(bits.dropLast())
    // A short bits buffer fails the whole image even when the crop lies in the rows that exist.
    #expect(DIB.decodeClip(Bytes(info), Bytes(short), keepAlpha: false, [0, 0, 1, 1], R4(0, 0, 1, 1)) == nil)
    #expect(DIB.decode(Bytes(info), Bytes(short), keepAlpha: false) == nil)
}

@Test func decodeClipDecodesOnlyTheCroppedPixels() throws {
    var rnd = XorShift(seed: 99)
    let (info, bits) = makeDib(400, -300, 24, &rnd)
    var decoded = 0
    let (img, _) = try #require(DIB.decodeClip(Bytes(info), Bytes(bits), keepAlpha: false, [10, 20, 8, 4], R4(0, 0, 8, 4), decoded: &decoded))
    #expect(img.w == 8 && img.h == 4)
    #expect(decoded == 8 * 4)
    // The whole bitmap decodes all 400 × 300.
    decoded = 0
    _ = try #require(DIB.decodeClip(Bytes(info), Bytes(bits), keepAlpha: false, [0, 0, 0, 0], R4(0, 0, 400, 300), decoded: &decoded))
    #expect(decoded == 400 * 300)
}

// MARK: tests.rs — crop window (0cca2f7d, fc5063c3)

/// #1899: a crop keeps what the file says down to a sliver (a header's bar is 2.7% of a page-sized metafile), and
/// junk sides give a finite part of the source with some area.
@Test func cropWindowKeepsASliverAndStaysFinite() throws {
    let c = Metafile.cropWindow(SIMD4(0, 0.51771, 0, 0.45485))
    #expect(c[0] == 0 && c[2] == 1 && Swift.abs(c[1] - 0.51771) < 1e-6 && Swift.abs(c[3] - 0.02744) < 1e-5, "\(c)")
    let pic = MetafilePicture(width: 100, height: 1000, items: [])
    let tf = try #require(pic.fit(MetafileRect(0, 0, 100, 27.44), crop: SIMD4(0, 0.51771, 0, 0.45485), rule: .wordCraft))
    // The kept band of the source (517.71..545.15) is the frame (0..27.44).
    let top = tf.apply(SIMD2(0, 517.71))
    let bottom = tf.apply(SIMD2(0, 545.15))
    #expect(Swift.abs(top.y) < 1e-3 && Swift.abs(bottom.y - 27.44) < 1e-3, "\(top) \(bottom)")
    let junk: [SIMD4<Float>] = [
        SIMD4(.nan, .infinity, -1, 2), SIMD4(repeating: 0.9), SIMD4(1, 1, 0, 0), SIMD4(.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.infinity, 0.5),
    ]
    for crop in junk {
        let w = Metafile.cropWindow(crop)
        let ok = (0 ..< 4).allSatisfy { w[$0].isFinite } && w[2] > 0 && w[3] > 0 && w[0] + w[2] <= 1 + 1e-9 && w[1] + w[3] <= 1 + 1e-9
        #expect(ok, "\(crop)")
    }
}

/// The narrowest crop on the largest frame layout makes (4000 pt, far down a 22-inch page) still places the source's
/// content: none of it is left out as far off the page.
@Test func theNarrowestCropOnTheLargestFrameKeepsItsContent() {
    let pic = MetafilePicture(width: 100, height: 100, items: [
        .bitmap(rect: SIMD4(0, 0, 100, 100), width: 1, height: 1, rgba: [255, 255, 255, 255], region: nil),
        .path(segs: [.move(0, 0), .line(100, 100)], fill: nil, stroke: S(C(0, 0, 0, 255), 1), evenOdd: false, region: nil),
    ])
    let frame = MetafileRect(1584, 1584, 5584, 5584)
    // The last sliver, the first sliver, and sides that overlap.
    for crop: SIMD4<Float> in [SIMD4(1, 1, 0, 0), SIMD4(0, 0, 1, 1), SIMD4(0.9999, 0.6, 0.5, 0.9999)] {
        #expect(pic.place(frame, crop: crop, rule: .wordCraft).count == 2, "\(crop)")
    }
}

/// deckcraft's rule (the default) widens a sliver crop to 5% of the axis; WordCraft's keeps it. Ordinary crops fit
/// the same under both.
@Test func cropRulesDifferOnlyOnSlivers() throws {
    let pic = MetafilePicture(width: 100, height: 1000, items: [])
    let frame = MetafileRect(0, 0, 100, 27.44)
    let sliver = SIMD4<Float>(0, 0.51771, 0, 0.45485)
    let dc = try #require(pic.fit(frame, crop: sliver))
    let wc = try #require(pic.fit(frame, crop: sliver, rule: .wordCraft))
    #expect(Swift.abs(dc.coeffs[3] - 27.44 / 50) < 1e-9, "5% of 1000 fills the frame")
    #expect(Swift.abs(wc.coeffs[3] - 27.44 / 27.44) < 1e-4)
    let ordinary = SIMD4<Float>(0.05, 0.1, 0, 0.2)
    let a = try #require(pic.fit(frame, crop: ordinary)).coeffs
    let b = try #require(pic.fit(frame, crop: ordinary, rule: .wordCraft)).coeffs
    #expect(zip(a, b).allSatisfy { Swift.abs($0 - $1) < 1e-9 }, "\(a) \(b)")
}

// MARK: tests.rs — poly groups (c98efffc)

/// A poly-polygon's group counts are file data: a long list of empty groups adds no ops, so it mustn't reserve room
/// for them either.
@Test func emptyPolyGroupsReserveNothing() {
    let pts = [P(0, 0), P(10, 0), P(10, 10)]
    let counts = [Int](repeating: 0, count: 100_000) + [3]
    var ops = subpaths(pts, counts, close: true)
    #expect(ops.count == 4, "M L L Z")
    #expect(ops.capacity <= 8, "capacity \(ops.capacity)")
    // Counts past the points are cut short, and the size still matches (Swift may round a reservation up to the
    // allocation's size, so the bound is that of the first check).
    ops = subpaths(pts, [2, 5, 4], close: false)
    #expect(ops.count == 3 && ops.capacity <= 8, "\(ops.count) \(ops.capacity)")
}

// MARK: lib.rs, place.rs — the text run (6931b8db)

@Test func textRunIsWordCraftsViewOfTheText() throws {
    let recs = [
        efont(24, 0, 400, 1, 0, "Segoe UI"),
        erec(37, h32(1)),
        erec(22, h32(0x18 | 2)),
        erec(24, h32(0x0000_FF00)),
        etext(true, 100, 50, [0x41, 0xD83D, 0xDE00, 0, 0], 0, [10, 6, 0, 3, 3]),
    ]
    let t = try firstText(parse(emf(recs, [0, 0, 200, 100], [0, 0, 5000, 2500])))
    let r = try #require(t.run)
    let m = t.transform
    // Trailing NULs go, with their advances; a surrogate pair is one character.
    #expect(r.text == "A\u{1F600}" && r.dx == [Float(10 * m[0]), Float(6 * m[0])], "\(r.dx)")
    #expect(r.x == Float(m[4]) && r.y == Float(m[5]) && r.angle == 0)
    #expect(r.size == Float(24 * m[3]) && r.cell, "a positive height is the cell height")
    #expect(r.font == "Segoe UI" && !r.bold && r.italic && r.color == C(0, 255, 0, 255))
    #expect(r.hAlign == .right && r.vAlign == .baseline)
}

@Test func textRunDefaultsAndEscapement() throws {
    // Height 0 is WordCraft's 16-unit cell; no face is Arial; 700 is bold; escapement 90° turns the baseline up.
    let recs = [efont(0, 900, 700, 0, 0, ""), erec(37, h32(1)), etext(true, 10, 10, [0x78], 0, [])]
    let t = try firstText(parse(emf(recs, [0, 0, 200, 100], [0, 0, 5000, 2500])))
    let r = try #require(t.run)
    let across = (t.transform[2] * t.transform[2] + t.transform[3] * t.transform[3]).squareRoot()
    #expect(r.size == Float(16 * across) && r.cell && r.font == "Arial" && r.bold && r.dx.isEmpty)
    #expect(Swift.abs(Double(r.angle) + .pi / 2) < 1e-6, "\(r.angle)")
    // A character height (negative) is the em size.
    let em = try firstText(parse(emf([efont(-12, 0, 400, 0, 0, "F"), erec(37, h32(1)), etext(true, 0, 0, [0x78], 0, [])], [0, 0, 200, 100], [0, 0, 5000, 2500])))
    #expect(em.run?.cell == false)
}

private func run(_ text: String, size: Float, cell: Bool = false, dx: [Float] = [], h: MetafileHAlign = .left, v: MetafileVAlign = .baseline) -> MetafileTextRun {
    MetafileTextRun(text: text, x: 0, y: 0, size: size, cell: cell, font: "F", bold: false, italic: false, color: C(0, 0, 0, 255), angle: 0, hAlign: h, vAlign: v, dx: dx)
}

@Test func textLayoutPlacesClustersByTheirCharacters() throws {
    let g = [(cluster: 0, advance: 500.0, xOffset: 0.0, yOffset: 0.0), (cluster: 1, advance: 600.0, xOffset: 0.0, yOffset: 100.0)]
    // The font's own advances at 10 units per em.
    var l = try #require(run("Ab", size: 10).layout(upem: 1000, ascent: 800, descent: 200, glyphs: g))
    #expect(l.em == 10 && l.baseline == 0 && l.glyphs == [SIMD2(0, 0), SIMD2(5, -1)])
    // The dx array places each character; centring moves the run back by half its dx width; top puts the baseline
    // an ascent down.
    l = try #require(run("Ab", size: 10, dx: [7, 3], h: .center, v: .top).layout(upem: 1000, ascent: 800, descent: 200, glyphs: g))
    #expect(l.baseline == 8 && l.glyphs == [SIMD2(-5, 8), SIMD2(2, 7)], "\(l.glyphs)")
    // A cell height takes the font's ascent + descent as the size.
    l = try #require(run("Ab", size: 12, cell: true).layout(upem: 1000, ascent: 900, descent: 300, glyphs: g))
    #expect(l.em == 10)
    // Clusters are UTF-8 offsets: "é" takes two bytes, so "b" starts at 2.
    let g2 = [(cluster: 0, advance: 500.0, xOffset: 0.0, yOffset: 0.0), (cluster: 2, advance: 500.0, xOffset: 0.0, yOffset: 0.0)]
    l = try #require(run("éb", size: 10, dx: [4, 6]).layout(upem: 1000, ascent: 800, descent: 200, glyphs: g2))
    #expect(l.glyphs == [SIMD2(0, 0), SIMD2(4, 0)])
    // A bad size lays out nothing.
    #expect(run("A", size: 0).layout(upem: 1000, ascent: 800, descent: 200, glyphs: g) == nil)
}

@Test func textRunPlacementTranslatesAndRotates() throws {
    var r = run("A", size: 10)
    (r.x, r.y, r.angle) = (10, 5, .pi / 2)
    let tf = try #require(r.placement(.scale(2, 2)))
    let o = tf.apply(SIMD2(0, 0)), e = tf.apply(SIMD2(1, 0))
    #expect(o == SIMD2(20, 10) && Swift.abs(e.x - 20) < 1e-6 && Swift.abs(e.y - 12) < 1e-6, "\(o) \(e)")
    #expect(r.placement(.translate(2e6, 0)) == nil)
}
