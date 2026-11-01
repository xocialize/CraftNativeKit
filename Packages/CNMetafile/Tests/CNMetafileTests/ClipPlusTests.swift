// Hostile text and brush records, byte budgets, clip regions and EMF+ records. Port of deckcraft
// crates/metafile/src/tests.rs and the in-file tests of crates/metafile/src/clip.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import CoreGraphics
@testable import CNMetafile
import Foundation
import ImageIO
import Testing

@Test func hostileTextAndBrushRecordsNeverPanic() throws {
    // A string longer than its record is cut to what the record holds.
    var p = try wmf200([wrec(0x0A32, cat([h16(0), h16(0), h16(0x7FFF), h16(0)]) + b("abcd"))])
    #expect(try firstText(p).text == "abcd")
    // The rectangle flag without room for the rectangle draws nothing.
    p = try wmf200([wrec(0x0A32, cat([h16(0), h16(0), h16(1), h16(6)]))])
    #expect(texts(p).isEmpty)
    // A face name with no terminator stops at 32 bytes.
    p = try wmf200([wfont(-10, 400, [0, 0, 0], 0, 0, [UInt8](repeating: 0x41, count: 40)), wrec(0x012D, h16(0)), wtext(0, 0, b("x"), 0, nil, [])])
    #expect(try firstText(p).font.family.utf8.count == 32)
    // A pattern brush whose DIB is cut short, or too big for a tile, still takes its handle slot and draws no
    // fill.
    let short = wrec(0x0142, cat([h16(5), h16(0), infoHeader(8, 8, 1, 32)]))
    let huge = wrec(0x0142, cat([h16(5), h16(0), infoHeader(300, 300, 1, 0) + [255, 255, 255, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 40 * 300)]))
    for brush in [short, huge] {
        let recs = [
            brush,
            wrec(0x02FA, cat([h16(0), h16(1), h16(0), h32(0xFF)])),
            wrec(0x012D, h16(0)),
            wrec(0x012D, h16(1)),
            wrec(0x041B, cat([h16(9), h16(9), h16(0), h16(0)])),
        ]
        let p = try wmf200(recs)
        #expect(p.items.count == 1, "\(p.items)")
        let (_, fill, stroke, _) = try pathSegs(item(p, 0))
        #expect(fill == C(255, 255, 255, 255) && stroke?.color == C(255, 0, 0, 255))
    }
    // EMF: the string offset past the record, a huge count, a dx offset past the record.
    let ab: [UInt8] = [0x61, 0, 0x62, 0]
    let bad = [
        erecAt(84, 80, [(44, 2), (48, 4000), (52, 0)], []),
        erecAt(84, 84, [(44, .max), (48, 76), (52, 0)], [(76, ab)]),
        erecAt(84, 80, [(44, 2), (48, 76), (52, 0), (72, 0xFFFF_FFF0)], [(76, ab)]),
        erecAt(82, 20, [(8, 1)], []),
        erecAt(94, 32, [(8, 1), (16, 0xFFFF_FFFF), (20, 40), (24, 0), (28, 0xFFFF_FFFF)], []),
        erecAt(108, 40, [(16, .max), (20, 0x300)], []),
    ]
    for r in bad { _ = try? parse(emf([r], [0, 0, 200, 100], [0, 0, 5000, 2500])) }
    p = try parse(emf([erecAt(84, 84, [(44, 2), (48, 76), (52, 0), (72, 0xFFFF_FFF0)], [(76, ab)])], [0, 0, 200, 100], [0, 0, 5000, 2500]))
    #expect(try firstText(p).dx.isEmpty, "a dx array past the record is dropped")
    // Mutated text and brush files.
    let wfile = wmf(
        [
            wfont(-20, 700, [1, 1, 1], 238, 450, b("Arial")),
            wrec(0x012D, h16(0)),
            wrec(0x0142, cat([h16(5), h16(0), monoDib([UInt8](repeating: 0x55, count: 8))])),
            wrec(0x012D, h16(1)),
            wrec(0x012E, h16(1)),
            wtext(5, 5, b("Hello"), 6, [0, 0, 50, 50], [1, 2, 3, 4, 5]),
            wrec(0x041B, cat([h16(9), h16(9), h16(0), h16(0)])),
        ],
        [0, 0, 100, 100]
    )
    let efile = emf(
        [efont(24, 900, 400, 1, 0, "Segoe UI"), erec(37, h32(1)), etext(true, 1, 2, [0x41, 0xD83D, 0xDE00], 0x2000, [1, 2, 3, 4, 5, 6])],
        [0, 0, 200, 100],
        [0, 0, 5000, 2500]
    )
    var rng = Lcg(0x9E37_79B9_7F4A_7C15)
    for file in [wfile, efile] {
        for n in 0 ... file.count { _ = try? parse(Array(file[..<n])) }
        for _ in 0 ..< 1500 {
            var buf = file
            for _ in 0 ..< 6 {
                let at = Int(rng.rnd()) % buf.count
                buf[at] = UInt8(truncatingIfNeeded: rng.rnd())
            }
            _ = try? parse(buf)
        }
    }
}

@Test func textItemsAreCappedLikeAnyOther() throws {
    let t = wtext(0, 0, b("x"), 0, nil, [])
    let p = try wmf200([[UInt8]](repeating: t, count: Metafile.maxItems + 5))
    #expect(p.items.count == Metafile.maxItems)
}

@Test func patternBrushPixelsCountAgainstTheByteBudget() throws {
    // 256 × 256 one-bit pattern brushes (256 KiB of RGBA each): far fewer than the object table holds fit the
    // budget, and the parse stops there.
    let dib = infoHeader(256, 256, 1, 0) + [255, 255, 255, 0, 0, 0, 0, 0] + [UInt8](repeating: 0x55, count: 32 * 256)
    let brush = wrec(0x0142, cat([h16(5), h16(0), dib]))
    var recs = [[UInt8]](repeating: brush, count: 1100)
    recs.append(wrec(0x041B, cat([h16(9), h16(9), h16(0), h16(0)])))
    let p = try wmf200(recs)
    #expect(p.items.isEmpty, "the parse stopped at the budget: \(p.items.count)")
}

@Test func emfIntersectClipRectLimitsLaterRecordsOnly() throws {
    let full = cat([e32(0), e32(0), e32(80), e32(40)])
    let clip = cat([e32(10), e32(5), e32(40), e32(30)])
    let p = try parse(emf([erec(43, full), erec(30, clip), erec(43, full)], [0, 0, 80, 40], [0, 0, 0, 0]))
    #expect(p.items.count == 2)
    #expect(try region(item(p, 0)) == nil)
    #expect(try region(item(p, 1)) == [SIMD4(10, 5, 40, 30)])
}

@Test func emfClipFollowsTheWorldTransformAndSaveRestoresIt() throws {
    let rect = cat([e32(0), e32(0), e32(10), e32(10)])
    let clip = cat([e32(0), e32(0), e32(5), e32(5)])
    var p = try parse(emf([erec(35, xformBytes([2, 0, 0, 2, 0, 0])), erec(30, clip), erec(43, rect)], [0, 0, 20, 20], [0, 0, 0, 0]))
    #expect(try region(item(p, 0)) == [SIMD4(0, 0, 10, 10)])

    let full = cat([e32(0), e32(0), e32(40), e32(20)])
    let recs = [erec(43, full), erec(33, []), erec(30, clip), erec(43, full), erec(34, e32(-1)), erec(43, full)]
    p = try parse(emf(recs, [0, 0, 40, 20], [0, 0, 0, 0]))
    #expect(p.items.count == 3)
    #expect(try region(item(p, 0)) == nil)
    #expect(try region(item(p, 1)) == [SIMD4(0, 0, 5, 5)])
    #expect(try region(item(p, 2)) == nil)
}

@Test func emfExtSelectClipRgnCopiesAndIntersectsRectangles() throws {
    var data = cat([h32(32), h32(1), h32(2), h32(32), e32(0), e32(0), e32(50), e32(20)])
    data += cat([e32(0), e32(0), e32(10), e32(20), e32(30), e32(0), e32(50), e32(20)])
    let payload = cat([h32(UInt32(data.count)), h32(5), data])
    let rect = cat([e32(0), e32(0), e32(50), e32(20)])
    var p = try parse(emf([erec(75, payload), erec(43, rect)], [0, 0, 50, 20], [0, 0, 0, 0]))
    #expect(try region(item(p, 0)) == [SIMD4(0, 0, 10, 20), SIMD4(30, 0, 50, 20)])

    let and = cat([h32(0), h32(1)])
    // A zero-length region selects the default clip, so the next rectangle is not clipped.
    p = try parse(emf([erec(75, payload), erec(75, and), erec(43, rect)], [0, 0, 50, 20], [0, 0, 0, 0]))
    #expect(try region(item(p, 0)) == nil)

    let overlap = cat([e32(40), e32(0), e32(80), e32(20)])
    p = try parse(emf([erec(75, payload), erec(30, overlap), erec(43, rect)], [0, 0, 80, 20], [0, 0, 0, 0]))
    #expect(try region(item(p, 0)) == [SIMD4(40, 0, 50, 20)])
}

@Test func emfExcludeClipRectCutsTheSurface() throws {
    let hole = cat([e32(20), e32(0), e32(40), e32(40)])
    let rect = cat([e32(0), e32(0), e32(80), e32(40)])
    let p = try parse(emf([erec(29, hole), erec(43, rect)], [0, 0, 80, 40], [0, 0, 0, 0]))
    #expect(try region(item(p, 0)) == [SIMD4(0, 0, 20, 40), SIMD4(40, 0, 80, 40)])
}

@Test func anEmptyClipDropsLaterDrawing() throws {
    let empty = cat([e32(5), e32(5), e32(5), e32(8)])
    let rect = cat([e32(0), e32(0), e32(20), e32(10)])
    let p = try parse(emf([erec(43, rect), erec(30, empty), erec(43, rect)], [0, 0, 20, 10], [0, 0, 0, 0]))
    #expect(p.items.count == 1)
}

@Test func wmfIntersectClipRectLimitsLaterRecords() throws {
    let clip = cat([h16(30), h16(40), h16(5), h16(10)])
    let rect = cat([h16(40), h16(80), h16(0), h16(0)])
    let p = try parse(wmf([wrec(0x0416, clip), wrec(0x041B, rect)], nil))
    #expect(try region(item(p, 0)) == [SIMD4(10, 5, 40, 30)])
}

// MARK: - EMF+

func f32s(_ v: [Float]) -> [UInt8] { v.flatMap(f32b) }

/// One EMF+ record: type, flags, size, data size, data (padded to 4).
func prec(_ typ: UInt16, _ flags: UInt16, _ data: [UInt8]) -> [UInt8] {
    var d = data
    while d.count % 4 != 0 { d.append(0) }
    return u16b(typ) + u16b(flags) + h32(UInt32(12 + d.count)) + h32(UInt32(d.count)) + d
}

/// An EMR_COMMENT carrying EMF+ records.
func plusComment(_ recs: [[UInt8]]) -> [UInt8] {
    let body = recs.flatMap { $0 }
    return erec(70, h32(UInt32(body.count + 4)) + h32(0x2B46_4D45) + body)
}

/// EMF+ header: dual (bit 0) or EMF+ only, 96 dpi.
func plusHeader(_ dual: Bool) -> [UInt8] {
    prec(0x4001, dual ? 1 : 0, cat([h32(0xDBC0_1002), h32(0), h32(96), h32(96)]))
}

func solidPen(_ argb: UInt32, _ width: Float) -> [UInt8] {
    cat([h32(0xDBC0_1002), h32(0), h32(0), h32(0), f32s([width]), h32(0xDBC0_1002), h32(0), h32(argb)])
}

@Test func emfplusOnlyFillRectsWithArgbColour() throws {
    let fill = prec(0x400A, 0x8000, cat([h32(0xFF00_80FF), h32(1), f32s([10, 20, 30, 40])]))
    let p = try parse(emf([plusComment([plusHeader(false), fill])], [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(p.items.count == 1)
    let (segs, f, stroke, _) = try pathSegs(item(p, 0))
    #expect(f == C(0x00, 0x80, 0xFF, 0xFF))
    #expect(stroke == nil)
    // Geometry is placed relative to the drawing's bounding box (no frame given).
    #expect((p.width, p.height) == (30, 40))
    #expect(try seg(segs, 0) == .move(0, 0))
    #expect(segs.contains(.line(30, 40)))
}

@Test func emfplusDualFilesDrawOnlyTheEmfRecords() throws {
    let fill = prec(0x400A, 0x8000, cat([h32(0xFFFF_0000), h32(1), f32s([0, 0, 5, 5])]))
    let gdi = erec(43, cat([e32(0), e32(0), e32(9), e32(9)]))
    let p = try parse(emf([plusComment([plusHeader(true), fill]), gdi], [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(p.items.count == 1)
    #expect(try pathSegs(item(p, 0)).1 == C(255, 255, 255, 255))
}

@Test func emfplusPenObjectDrawsLinesUnderAScaleTransform() throws {
    let pen = prec(0x4008, 0x0200 | 3, solidPen(0xFF00_FF00, 2))
    let scale = prec(0x402E, 0, f32s([2, 3]))
    let lines = prec(0x400D, 3, cat([h32(2), f32s([1, 1, 4, 2])]))
    let p = try parse(emf([plusComment([plusHeader(false), pen, scale, lines])], [0, 0, 0, 0], [0, 0, 0, 0]))
    let (segs, fill, stroke, _) = try pathSegs(item(p, 0))
    // (1,1)-(4,2) scaled by (2,3) is (2,3)-(8,6), placed relative to its bounding box.
    #expect(segs == [.move(0, 0), .line(6, 3)])
    #expect(fill == nil)
    let s = try #require(stroke)
    #expect(s.color == C(0, 255, 0, 255))
    #expect(s.width > 0)
}

@Test func emfplusPathObjectFillsWithBrushObjectAndRestoreUndoesTransform() throws {
    let brush = prec(0x4008, 0x0100 | 1, cat([h32(0xDBC0_1002), h32(0), h32(0x8012_3456)]))
    // Triangle: start, line, line|close.
    let path = prec(0x4008, 0x0300 | 2, cat([h32(0xDBC0_1002), h32(3), h32(0), f32s([0, 0, 10, 0, 0, 10]), [0, 1, 0x81]]))
    let save = prec(0x4025, 0, h32(7))
    let mv = prec(0x402D, 0, f32s([100, 0]))
    let restore = prec(0x4026, 0, h32(7))
    let fill = prec(0x4014, 2, h32(1))
    let p = try parse(emf([plusComment([plusHeader(false), brush, path, save, mv, restore, fill])], [0, 0, 0, 0], [0, 0, 0, 0]))
    let (segs, f, _, _) = try pathSegs(item(p, 0))
    #expect(f == C(0x12, 0x34, 0x56, 0x80))
    #expect(segs == [.move(0, 0), .line(10, 0), .line(0, 10), .close])
}

@Test func emfplusGarbageRecordsNeverPanic() {
    var s: UInt32 = 0x1234_5678
    func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { let k = n % 32; return k == 0 ? v : v << k | v >> (32 - k) }
    for _ in 0 ..< 300 {
        var recs = [plusHeader(false)]
        for _ in 0 ..< 6 {
            s = s &* 1_103_515_245 &+ 12_345
            let typ = 0x4000 + UInt16(truncatingIfNeeded: s >> 16) % 0x40
            let data = (0 ..< s % 64).map { UInt8(truncatingIfNeeded: rotl(s, $0)) }
            recs.append(prec(typ, UInt16(truncatingIfNeeded: s >> 8), data))
        }
        _ = try? parse(emf([plusComment(recs)], [0, 0, 0, 0], [0, 0, 0, 0]))
    }
}

func plusPic(_ recs: [[UInt8]]) throws -> MetafilePicture {
    try parse(emf([plusComment([plusHeader(false)] + recs)], [0, 0, 0, 0], [0, 0, 0, 0]))
}

func u16s(_ s: String) -> [UInt8] { s.utf16.flatMap(u16b) }

/// A 2 x 2 32bpp ARGB bitmap image object: red, green / blue, white.
func bitmap2x2() -> [UInt8] {
    let px: [UInt32] = [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF, 0xFFFF_FFFF]
    return cat([h32(0xDBC0_1002), h32(1), h32(2), h32(2), h32(8), h32(0x0026_200A), h32(0), px.flatMap(h32)])
}

func drawImage(_ id: UInt16, _ dst: [Float]) -> [UInt8] {
    prec(0x401A, id, cat([h32(0), h32(2), f32s([0, 0, 2, 2]), f32s(dst)]))
}

@Test func emfplusDrawImagePlacesTheBitmap() throws {
    let p = try plusPic([prec(0x4008, 0x0500 | 4, bitmap2x2()), drawImage(4, [10, 10, 20, 40])])
    let b = try bitmap(item(p, 0))
    #expect((b.width, b.height) == (2, 2))
    #expect(b.rect == SIMD4(0, 0, 20, 40))
    #expect(Array(b.rgba[..<8]) == [255, 0, 0, 255, 0, 255, 0, 255])
    #expect(Array(b.rgba[8 ..< 12]) == [0, 0, 255, 255])
}

@Test func emfplusObjectSplitAcrossRecordsIsJoined() throws {
    let obj = bitmap2x2()
    let (a, bb) = (Array(obj[..<20]), Array(obj[20...]))
    let first = prec(0x4008, 0x8000 | 0x0500 | 1, cat([h32(UInt32(obj.count)), a]))
    let second = prec(0x4008, 0x0500 | 1, bb)
    let p = try plusPic([first, second, drawImage(1, [0, 0, 4, 4])])
    let b = try bitmap(item(p, 0))
    #expect(b.width == 2 && b.height == 2)
}

/// A PNG of `w` × 1 pixels of one colour, written with ImageIO (deckcraft writes it with the `image` crate).
private func png(_ w: Int, _ rgba: [UInt8]) throws -> [UInt8] {
    var px = [UInt8]()
    for _ in 0 ..< w { px += rgba }
    let provider = try #require(CGDataProvider(data: Data(px) as CFData))
    let image = try #require(CGImage(
        width: w, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return [UInt8](out as Data)
}

@Test func emfplusCompressedPngImageDecodes() throws {
    let obj = try cat([h32(0xDBC0_1002), h32(1), h32(0), h32(0), h32(0), h32(0), h32(1), png(3, [1, 2, 3, 255])])
    let draw = prec(0x401A, 2, cat([h32(0), h32(2), f32s([0, 0, 3, 1]), f32s([0, 0, 3, 1])]))
    let p = try plusPic([prec(0x4008, 0x0500 | 2, obj), draw])
    let b = try bitmap(item(p, 0))
    #expect(b.width == 3 && b.height == 1 && Array(b.rgba.prefix(4)) == [1, 2, 3, 255])
}

func fontObj(_ family: String, _ em: Float, _ unit: UInt32, _ style: UInt32) -> [UInt8] {
    cat([h32(0xDBC0_1002), f32s([em]), h32(unit), h32(style), h32(0), h32(UInt32(family.utf16.count)), u16s(family)])
}

@Test func emfplusDrawStringWithFontAndCentredFormat() throws {
    let font = prec(0x4008, 0x0600 | 3, fontObj("Calibri", 12, 2, 1))
    // String format: centre alignment, no clip.
    let fmt = prec(0x4008, 0x0700 | 4, cat([h32(0xDBC0_1002), h32(0x4000), h32(0), h32(1), h32(0)]))
    let s = prec(0x401C, 0x8000 | 3, cat([h32(0xFF11_2233), h32(4), h32(2), f32s([0, 0, 100, 20]), u16s("Hi")]))
    let p = try plusPic([font, fmt, prec(0x400A, 0x8000, cat([h32(0xFFFF_FFFF), h32(1), f32s([0, 0, 100, 20])])), s])
    let t = try firstText(p)
    #expect(t.text == "Hi")
    #expect(t.font.family == "Calibri")
    #expect(t.font.weight == 700)
    #expect(close(t.font.height, -12))
    #expect(t.color == C(0x11, 0x22, 0x33, 0xFF))
    #expect(t.hAlign == .center)
    #expect(close(Float(t.transform[4]), 50))
    #expect(t.background == nil)
    #expect(t.clip == nil)
}

@Test func emfplusDriverStringUsesCharacterCodesAndPositions() throws {
    let font = prec(0x4008, 0x0600, fontObj("Arial", 10, 0, 0))
    let pos = f32s([5, 30, 11, 30])
    let s = prec(0x4036, 0x8000, cat([h32(0xFF00_0000), h32(1), h32(0), h32(2), u16s("Ab"), pos]))
    let p = try plusPic([prec(0x400A, 0x8000, cat([h32(0xFFFF_FFFF), h32(1), f32s([0, 0, 50, 50])])), font, s])
    let t = try text(item(p, 1))
    #expect(t.text == "Ab")
    #expect(t.dx == [6, 6])
    #expect(t.vAlign == .baseline)
    #expect(close(Float(t.transform[4]), 5) && close(Float(t.transform[5]), 30))
}

@Test func emfplusGlyphIndexDriverStringsMapBackInCoreFontsOnly() throws {
    // Glyph indices (no CmapLookup): 36, 69 are "Ab" in Arial's standard glyph order.
    func gi() -> [UInt8] { prec(0x4036, 0x8000, cat([h32(0xFF00_0000), h32(0), h32(0), h32(2), h16(36), h16(69), f32s([0, 0, 6, 0])])) }
    let p = try plusPic([prec(0x4008, 0x0600, fontObj("Arial", 10, 0, 0)), gi()])
    #expect(try text(item(p, 0)).text == "Ab", "\(p.items)")
    // An unknown font's glyph indices cannot be mapped: nothing is drawn.
    #expect(try plusPic([prec(0x4008, 0x0600, fontObj("Calibri", 10, 0, 0)), gi()]).items.isEmpty)
}

@Test func emfplusLinearGradientFillsWithAShadedTile() throws {
    // Red to blue across x = 0..100.
    let brush = cat([h32(0xDBC0_1002), h32(4), h32(0), h32(0), f32s([0, 0, 100, 10]), h32(0xFFFF_0000), h32(0xFF00_00FF), h32(0), h32(0)])
    let fill = prec(0x400A, 0, cat([h32(5), h32(1), f32s([0, 0, 100, 10])]))
    let p = try plusPic([prec(0x4008, 0x0100 | 5, brush), fill])
    let tile = try patternOf(item(p, 0))
    func px(_ x: Int) -> MetafileColor { tilePx(tile, x, 0) }
    #expect(px(0)[0] > 240 && px(0)[2] < 15, "left is red: \(px(0))")
    let right = Swift.min(Int(tile.width) - 2, 127)
    #expect(px(right)[2] > 230 && px(right)[0] < 25, "right is blue: \(px(right))")
}

@Test func emfplusHatchBrushFillsWithAn8x8Tile() throws {
    let brush = cat([h32(0xDBC0_1002), h32(1), h32(4), h32(0xFF00_0000), h32(0xFFFF_FFFF)])
    let fill = prec(0x400A, 0, cat([h32(0), h32(1), f32s([0, 0, 16, 16])]))
    let p = try plusPic([prec(0x4008, 0x0100, brush), fill])
    let tile = try patternOf(item(p, 0))
    #expect(tile.width == 8 && tile.height == 8)
}

@Test func emfplusClipRectCutsFillsStrokesAndImages() throws {
    let clip = prec(0x4032, 0, f32s([0, 0, 50, 50]))
    let fill = prec(0x400A, 0x8000, cat([h32(0xFF00_0000), h32(1), f32s([25, 25, 50, 50])]))
    let outside = prec(0x400A, 0x8000, cat([h32(0xFF00_0000), h32(1), f32s([60, 60, 5, 5])]))
    let pen = prec(0x4008, 0x0200 | 1, solidPen(0xFF00_FF00, 1))
    let line = prec(0x400D, 1, cat([h32(2), f32s([0, 10, 100, 10])]))
    let img = prec(0x4008, 0x0500 | 2, bitmap2x2())
    let p = try plusPic([clip, fill, outside, pen, line, img, drawImage(2, [40, 0, 20, 20])])
    #expect(p.items.count == 3, "\(p.items)")
    var (segs, _, _, _) = try pathSegs(item(p, 0))
    let xs = segs.compactMap { s -> Float? in
        switch s {
        case .move(let x, _), .line(let x, _): x
        default: nil
        }
    }
    // Picture coordinates start at the drawing's left edge (0): the square is cut at x = 50.
    #expect(xs.allSatisfy { $0 <= 50 + 1e-3 }, "\(segs)")
    segs = try pathSegs(item(p, 1)).0
    guard case .line(let x, _) = try seg(segs, 1) else { Issue.record("\(segs)"); return }
    #expect(close(x, 50), "\(segs)")
    let b = try bitmap(item(p, 2))
    #expect(b.width == 1)
    #expect(close(b.rect[2], 10))
}

@Test func emfplusResetClipAndRestoreBringDrawingBack() throws {
    func fill() -> [UInt8] { prec(0x400A, 0x8000, cat([h32(0xFF00_0000), h32(1), f32s([10, 10, 5, 5])])) }
    var p = try plusPic([prec(0x4025, 0, h32(1)), prec(0x4032, 0, f32s([0, 0, 1, 1])), fill(), prec(0x4026, 0, h32(1)), fill()])
    #expect(p.items.count == 1)
    p = try plusPic([prec(0x4032, 0, f32s([0, 0, 1, 1])), fill(), prec(0x4031, 0, []), fill()])
    #expect(p.items.count == 1)
}

@Test func emfplusRegionClipIntersectsRectangles() throws {
    // Region: intersect(rect 0,0,30,30 ; rect 10,10,100,100) = 10..30.
    func rect(_ r: [Float]) -> [UInt8] { cat([h32(0x1000_0000), f32s(r)]) }
    let region = cat([h32(0xDBC0_1002), h32(2), h32(1), rect([0, 0, 30, 30]), rect([10, 10, 90, 90])])
    let fill = prec(0x400A, 0x8000, cat([h32(0xFF00_0000), h32(1), f32s([0, 0, 100, 100])]))
    let p = try plusPic([prec(0x4008, 0x0400 | 6, region), prec(0x4034, 6, []), fill])
    #expect((p.width, p.height) == (20, 20))
}

@Test func emfplusRegionPathCannotReadIntoItsSibling() throws {
    func rect(_ r: [Float]) -> [UInt8] { cat([h32(0x1000_0000), f32s(r)]) }
    // The path declares only its 12-byte header, but claims three points. The following
    // rectangle must not supply those points or be parsed twice as the next node.
    let path = cat([h32(0x1000_0001), h32(12), h32(0), h32(3), h32(0)])
    let region = cat([h32(0xDBC0_1002), h32(2), h32(1), path, rect([10, 10, 20, 20])])
    let fill = prec(0x400A, 0x8000, cat([h32(0xFF00_0000), h32(1), f32s([0, 0, 100, 100])]))
    let p = try plusPic([prec(0x4008, 0x0400 | 6, region), prec(0x4034, 6, []), fill])
    #expect(p.items.count == 1)
    #expect((p.width, p.height) == (100, 100))
}

@Test func emfplusRegionPathKeepsItsShape() throws {
    var pathData = cat([h32(0), h32(4), h32(0x4000)])
    for (x, y) in [(10, 10), (30, 10), (30, 30), (10, 30)] { pathData += h16(x) + h16(y) }
    pathData += [0, 1, 1, 0x81]
    let pathNode = cat([h32(0x1000_0001), h32(UInt32(pathData.count)), pathData])
    let region = cat([h32(0xDBC0_1002), h32(1), pathNode])
    let fill = prec(0x400A, 0x8000, cat([h32(0xFF00_0000), h32(1), f32s([0, 0, 100, 100])]))
    let p = try plusPic([prec(0x4008, 0x0400 | 6, region), prec(0x4034, 6, []), fill])
    #expect((p.width, p.height) == (20, 20))
}

@Test func emfplusPieAndArc() throws {
    // A quarter pie from 0 to 90 degrees in a 0..100 circle: centre, then (100, 50) round to (50, 100).
    let pie = prec(0x4010, 0x8000, cat([h32(0xFF00_0000), f32s([0, 90]), f32s([0, 0, 100, 100])]))
    var p = try plusPic([pie])
    var (segs, fill, _, _) = try pathSegs(item(p, 0))
    #expect(fill == C(0, 0, 0, 255))
    #expect(try seg(segs, 0) == .move(0, 0))
    #expect(try seg(segs, 1) == .line(50, 0))
    guard case .cubic(_, _, _, _, let x, let y) = try seg(segs, 2) else { Issue.record("\(segs)"); return }
    #expect(close(x, 0) && close(y, 50), "\(segs)")
    #expect(try seg(segs, 3) == .close)
    // A half-circle arc stroke is two cubics.
    let pen = prec(0x4008, 0x0200, solidPen(0xFF00_0000, 1))
    let arc = prec(0x4012, 0, cat([f32s([180, -180]), f32s([0, 0, 100, 100])]))
    p = try plusPic([pen, arc])
    (segs, fill, _, _) = try pathSegs(item(p, 0))
    #expect(segs.count == 3, "\(segs)")
}

private func points(_ segs: [MetafileSeg]) -> [(Float, Float)] {
    segs.compactMap {
        switch $0 {
        case .move(let x, let y), .line(let x, let y): (x, y)
        default: nil
        }
    }
}

@Test func emfplusConvexClipPathCutsToTheShapeNotItsBox() throws {
    // A diamond clip path (0,50) (50,0) (100,50) (50,100): the corner of a full square fill is cut away.
    let diamond = cat([h32(0xDBC0_1002), h32(4), h32(0), f32s([0, 50, 50, 0, 100, 50, 50, 100]), [0, 1, 1, 0x81]])
    let fill = prec(0x400A, 0x8000, cat([h32(0xFF00_0000), h32(1), f32s([0, 0, 100, 100])]))
    let p = try plusPic([prec(0x4008, 0x0300 | 9, diamond), prec(0x4033, 9, []), fill])
    let pts = try points(pathSegs(item(p, 0)).0)
    #expect(!pts.contains { close($0.0, 0) && close($0.1, 0) }, "corner kept: \(pts)")
    #expect(pts.allSatisfy { Swift.abs($0.0 - 50) + Swift.abs($0.1 - 50) <= 50 + 1e-3 }, "\(pts)")
}

@Test func emfplusDrawStringWrapsToTheLayoutWidth() throws {
    let font = prec(0x4008, 0x0600, fontObj("Arial", 10, 0, 0))
    let str = "alpha beta gamma delta"
    let s = prec(0x401C, 0x8000, cat([h32(0xFF00_0000), h32(9), h32(UInt32(str.utf16.count)), f32s([0, 0, 60, 100]), u16s(str)]))
    let fill = prec(0x400A, 0x8000, cat([h32(0xFFFF_FFFF), h32(1), f32s([0, 0, 60, 100])]))
    let p = try plusPic([fill, font, s])
    #expect(texts(p).map(\.text) == ["alpha beta", "gamma delta"])
}

@Test func emfplusNestedMetafileImageDrawsItsItemsIntoTheDestination() throws {
    // The nested picture: a plain EMF with a 10 x 10 rectangle (white brush, black pen).
    let inner = emf([erec(43, cat([e32(0), e32(0), e32(10), e32(10)]))], [0, 0, 0, 0], [0, 0, 0, 0])
    let obj = cat([h32(0xDBC0_1002), h32(2), h32(3), h32(UInt32(inner.count)), inner])
    let p = try plusPic([prec(0x4008, 0x0500 | 3, obj), drawImage(3, [0, 0, 40, 20])])
    #expect(p.items.count == 1)
    #expect((p.width, p.height) == (40, 20))
    let (segs, fill, _, _) = try pathSegs(item(p, 0))
    #expect(fill == C(255, 255, 255, 255))
    #expect(segs.contains(.line(40, 20)), "\(segs)")
}

/// Curves and a region fill, as an EMF+ only file (also written to `$DECKCRAFT_EMF_OUT` to look at).
func curvesFile() -> [UInt8] {
    let pen = prec(0x4008, 0x0200 | 1, solidPen(0xFF20_60C0, 3))
    // A closed curve through a diamond's corners, filled orange.
    let diamond = f32s([100, 10, 190, 100, 100, 190, 10, 100])
    let fill = prec(0x4016, 0x8000, cat([h32(0xFFE0_8020), f32s([0.5]), h32(4), diamond]))
    let outline = prec(0x4017, 1, cat([f32s([0.5]), h32(4), diamond]))
    // An open curve (a smoothed line chart): all four segments of five points.
    let line = prec(0x4018, 1, cat([f32s([0.5]), h32(0), h32(4), h32(5), f32s([210, 150, 260, 60, 310, 120, 360, 30, 410, 90])]))
    // A green rectangle region, filled.
    let region = cat([h32(0xDBC0_1002), h32(0), h32(0x1000_0000), f32s([220, 160, 180, 30])])
    let fillRegion = prec(0x4013, 0x8000 | 2, h32(0xFF30_A040))
    // A cream background first.
    let clear = prec(0x4009, 0, h32(0xFFF4_EED8))
    let all = [plusHeader(false), clear, pen, fill, outline, line, prec(0x4008, 0x0400 | 2, region), fillRegion, prec(0x4002, 0, [])]
    return emf([plusComment(all)], [0, 0, 420, 200], [0, 0, 0, 0])
}

private func count(_ segs: [MetafileSeg], _ f: (MetafileSeg) -> Bool) -> Int { segs.filter(f).count }
private func isCubic(_ s: MetafileSeg) -> Bool { if case .cubic = s { true } else { false } }
private func isLine(_ s: MetafileSeg) -> Bool { if case .line = s { true } else { false } }

@Test func emfplusCardinalCurvesAndRegionFill() throws {
    let bytes = curvesFile()
    if let path = ProcessInfo.processInfo.environment["DECKCRAFT_EMF_OUT"] {
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
    }
    let p = try parse(bytes)
    #expect(p.items.count == 5, "\(p.items.count)")
    #expect(try pathSegs(item(p, 0)).1 == C(0xF4, 0xEE, 0xD8, 0xFF), "the clear comes first")
    // The closed curve: four cubics through the diamond's corners, closed.
    var (segs, fill, stroke, _) = try pathSegs(item(p, 1))
    #expect(fill == C(0xE0, 0x80, 0x20, 0xFF))
    #expect(count(segs, isCubic) == 4, "\(segs)")
    #expect(segs.last == .close)
    // The open curve: four cubics and no close; its controls bulge past the straight chords.
    (segs, fill, stroke, _) = try pathSegs(item(p, 3))
    #expect(fill == nil && stroke?.color == C(0x20, 0x60, 0xC0, 0xFF))
    #expect(count(segs, isCubic) == 4)
    #expect(!segs.contains(.close))
    // The region fill is its rectangle.
    (segs, fill, _, _) = try pathSegs(item(p, 4))
    #expect(fill == C(0x30, 0xA0, 0x40, 0xFF))
    #expect(count(segs, isLine) == 3, "\(segs)")
}

@Test func emfplusCurveOffsetsAndDegenerateInputAreSafe() throws {
    let pen = prec(0x4008, 0x0200 | 1, solidPen(0xFF00_0000, 1))
    // Segments from point 2 of 5, asking for more than there are: two segments.
    let line = prec(0x4018, 1, cat([f32s([0.5]), h32(2), h32(99), h32(5), f32s([0, 0, 10, 5, 20, 0, 30, 5, 40, 0])]))
    var p = try plusPic([pen, line])
    #expect(try count(pathSegs(item(p, 0)).0, isCubic) == 2)
    // One point, an offset past the end, a NaN tension, a missing region: nothing, no panic.
    let one = prec(0x4018, 1, cat([f32s([0.5]), h32(0), h32(1), h32(1), f32s([1, 1])]))
    let past = prec(0x4018, 1, cat([f32s([0.5]), h32(9), h32(9), h32(2), f32s([0, 0, 9, 9])]))
    let nan = prec(0x4017, 1, cat([f32s([.nan]), h32(3), f32s([0, 0, 9, 9, 0, 9])]))
    let noRegion = prec(0x4013, 0x8000 | 7, h32(0xFF00_0000))
    p = try plusPic([pen, one, past, nan, noRegion])
    #expect(try p.items.allSatisfy { try count(pathSegs($0).0, isCubic) == 0 })
}

@Test func emfplusClearPaintsTheWholeFrameAndTransparentClearsNothing() throws {
    let dot = prec(0x400A, 0x8000, cat([h32(0xFF00_0000), h32(1), f32s([40, 40, 10, 10])]))
    func clear(_ argb: UInt32) -> [UInt8] { prec(0x4009, 0, h32(argb)) }
    // 100 × 50 device units (0..2500 × 0..1250 hundredths of a millimetre at 0.04 units each).
    func file(_ recs: [[UInt8]]) throws -> MetafilePicture {
        try parse(emf([plusComment([plusHeader(false)] + recs)], [0, 0, 99, 49], [0, 0, 2500, 1250]))
    }
    // A translated, clipped world doesn't move or cut the clear.
    let shift = prec(0x402D, 0, f32s([30, 30]))
    let clip = prec(0x4032, 0, f32s([0, 0, 5, 5]))
    let p = try file([shift, clip, clear(0xFFFF_FFFF), prec(0x4031, 0, []), dot])
    #expect(p.items.count == 2)
    let (segs, fill, _, _) = try pathSegs(item(p, 0))
    #expect(fill == C(255, 255, 255, 255))
    let xs = points(segs).map(\.0)
    let span = xs.reduce(-Float.greatestFiniteMagnitude) { $0.rustMax($1) } - xs.reduce(Float.greatestFiniteMagnitude) { $0.rustMin($1) }
    #expect(Swift.abs(span - p.width) < 0.5, "clear spans \(span) of \(p.width)")
    // Transparent: only the dot.
    #expect(try file([clear(0x00FF_FFFF), dot]).items.count == 1)
    // No frame: nothing to clear.
    #expect(try plusPic([clear(0xFFFF_FFFF), dot]).items.count == 1)
}

@Test func emfplusWrapLineLinearPerformance() throws {
    let font = prec(0x4008, 0x0600, fontObj("Arial", 10, 0, 0))
    // Repeated words that wrap across lines
    let str = String(repeating: "word ", count: 500)
    let s = prec(0x401C, 0x8000, cat([h32(0xFF00_0000), h32(9), h32(UInt32(str.utf16.count)), f32s([0, 0, 100, 1000]), u16s(str)]))
    let fill = prec(0x400A, 0x8000, cat([h32(0xFFFF_FFFF), h32(1), f32s([0, 0, 100, 1000])]))
    let p = try plusPic([fill, font, s])
    let n = texts(p).count
    #expect(n > 10, "wrapped into multiple lines: \(n)")
}

@Test func clipPolygonWorkBound() {
    let poly = (0 ..< 2000).map { P(Double($0), Double($0)) }
    let clip = (0 ..< 2000).map { P(Double($0), Double($0)) }
    #expect(ClipRect.clipPolygon(poly, clip).isEmpty, "excessive polygon clip product rejected")
}

// MARK: - clip.rs in-file tests

@Test func intersectShrinksToTheOverlap() {
    var r = Clip.intersect(nil, R4(0, 0, 100, 50))
    r = Clip.intersect(r, R4(40, 10, 80, 40))
    #expect(r == [R4(40, 10, 80, 40)])
    #expect(Clip.intersect(r, R4(0, 0, 10, 10)) == [])
    #expect(Clip.intersect([R4(0, 0, 10, 20)], R4(40, 0, 80, 20)) == [])
}

@Test func modesCopyAndOrDiffAndXor() {
    let a: [R4]? = [R4(0, 0, 100, 40)]
    #expect(Clip.combine(a, [R4(10, 10, 30, 20)], Clip.rgnCopy, nil) == [R4(10, 10, 30, 20)])
    #expect(Clip.combine(a, [R4(50, 0, 150, 40)], Clip.rgnAnd, nil) == [R4(50, 0, 100, 40)])
    #expect(Clip.combine(a, [R4(200, 0, 210, 10)], Clip.rgnOr, nil)?.count == 2)
    #expect(Clip.combine(a, [R4(20, 0, 40, 40)], Clip.rgnDiff, nil) == [R4(0, 0, 20, 40), R4(40, 0, 100, 40)])
    let xor = Clip.combine(a, [R4(80, 0, 120, 40)], Clip.rgnXor, nil) ?? []
    #expect(xor.contains(R4(0, 0, 80, 40)))
    #expect(xor.contains(R4(100, 0, 120, 40)))
}

@Test func excludingFromTheDefaultClipUsesTheSurface() {
    #expect(Clip.exclude(nil, R4(10, 0, 20, 40), R4(0, 0, 40, 40)) == [R4(0, 0, 10, 40), R4(20, 0, 40, 40)])
    #expect(Clip.exclude(nil, R4(10, 0, 20, 40), nil) == nil)
}

@Test func aZeroAreaRectangleClearsAnIntersection() {
    #expect(Clip.intersect([R4(0, 0, 10, 10)], R4(5, 5, 5, 8)) == [])
}
