// Bitmaps and blends, placement, plain-WMF targets, text records, pattern and hatch brushes and the mix-mode
// idioms. Port of deckcraft crates/metafile/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
@testable import CNMetafile
import Testing

@Test func emfAlphablendUsesConstantAndPerPixelAlpha() throws {
    // Constant alpha 128 (BLENDFUNCTION bytes at 40: op, flags, constant, format) over a 24-bit DIB.
    let blend: [UInt8] = [0, 0, 128, 0]
    let dib = dib24BottomUp()
    let fields: [(Int, UInt32)] = [(24, 0), (28, 0), (32, 2), (36, 2), (44, 0), (48, 0), (100, 2), (104, 2)]
    let rec = dibRec(114, fields, [(40, blend)], Array(dib[..<40]), Array(dib[40...]))
    let p = try parse(emf([rec], [0, 0, 0, 0], [0, 0, 0, 0]))
    let rgba = try bitmap(item(p, 0)).rgba
    #expect(stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] } == [128, 128, 128, 128])
    // Per-pixel alpha (AC_SRC_ALPHA) over a 32-bit premultiplied DIB: BGRA 0, 0, 128, 128 is straight red at half
    // alpha, and the constant 128 halves the alpha again.
    func onePx(_ constant: UInt8, _ bgra: [UInt8]) throws -> [UInt8] {
        let blend: [UInt8] = [0, 0, constant, 1]
        let fields: [(Int, UInt32)] = [(24, 0), (28, 0), (32, 1), (36, 1), (44, 0), (48, 0), (100, 1), (104, 1)]
        let rec = dibRec(114, fields, [(40, blend)], infoHeader(1, 1, 32, 4), bgra)
        return try bitmap(item(parse(emf([rec], [0, 0, 0, 0], [0, 0, 0, 0])), 0)).rgba
    }
    #expect(try onePx(255, [0, 0, 128, 128]) == [255, 0, 0, 128])
    #expect(try onePx(128, [0, 0, 128, 128]) == [255, 0, 0, 64])
    #expect(try onePx(255, [10, 20, 64, 128]) == [128, 40, 20, 128], "rounded to the nearest value")
}

@Test func emfSrcandMaskDrawsAllButItsWhitePixels() throws {
    // SRCAND over white paper is the source itself; white keeps the destination, so it is transparent.
    let dib = dib24BottomUp()
    let rec = bitbltRec(0x0088_00C6, [0, 0, 2, 2], Array(dib[..<40]), Array(dib[40...]))
    let p = try parse(emf([rec], [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(try bitmap(item(p, 0)).rgba == [255, 0, 0, 255, 255, 255, 255, 0, 0, 0, 255, 255, 0, 255, 0, 255])
}

@Test func emfSrcpaintMakesBlackPixelsTransparent() throws {
    // A 2 x 1 DIB: black, then red. SRCPAINT leaves black transparent; SRCCOPY keeps it opaque.
    let info = infoHeader(2, 1, 24, 8)
    let bits: [UInt8] = [0, 0, 0, 0, 0, 255, 0, 0]
    var p = try parse(emf([bitbltRec(0x00EE_0086, [0, 0, 2, 1], info, bits)], [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(try bitmap(item(p, 0)).rgba == [0, 0, 0, 0, 255, 0, 0, 255])
    p = try parse(emf([bitbltRec(0x00CC_0020, [0, 0, 2, 1], info, bits)], [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(try bitmap(item(p, 0)).rgba == [0, 0, 0, 255, 255, 0, 0, 255])
}

@Test func wmfDibPaletteEntriesAreSkippedBeforeTheBits() throws {
    // A 24-bit DIB with biClrUsed = 2 carries two RGBQUADs (8 bytes) before its pixel bits.
    var info = infoHeader(2, 2, 24, 16)
    put(&info, 32, h32(2))
    let dib = info + [UInt8](repeating: 9, count: 8) + dib24BottomUp()[40...]
    let params = cat([h32(0x00CC_0020), h16(0), h16(2), h16(2), h16(0), h16(0), h16(10), h16(20), h16(0), h16(0), dib])
    let p = try parse(wmf([wrec(0x0F43, params)], nil))
    #expect(try bitmap(item(p, 0)).rgba == dib24RGBA)
}

@Test func emfPointCountsPastTheBudgetAreRejected() throws {
    // A count of 4 billion points in a record that cannot hold them: nothing is drawn and nothing is allocated.
    let poly = [UInt8](repeating: 0, count: 16) + cat([h32(.max), h32(0), h32(0)])
    let groups = [UInt8](repeating: 0, count: 16) + cat([h32(.max), h32(.max), h32(1)])
    let p = try parse(emf([erec(4, poly), erec(7, groups)], [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(p.items.isEmpty)
}

@Test func emfPolypolygonCountsMustFitTheRecord() throws {
    // A polygon count within the point budget in a record too short to hold the counts draws nothing.
    let short = [UInt8](repeating: 0, count: 16) + cat([h32(UInt32(Metafile.maxPathOps)), h32(3), h32(3)])
    // POLYPOLYGON16: two triangles of three points each.
    let two = [UInt8](repeating: 0, count: 16) + cat([h32(2), h32(6), h32(3), h32(3)]) + [0, 0, 10, 0, 0, 10, 20, 0, 30, 0, 20, 10].flatMap(h16)
    let p = try parse(emf([erec(91, short), erec(91, two)], [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(p.items.count == 1)
    let (segs, _, _, _) = try pathSegs(item(p, 0))
    #expect(segs.filter { if case .move = $0 { true } else { false } }.count == 2, "\(segs)")
}

/// EMR_EXTCREATEPEN into slot 1 with LogPenEx style, width and brush style, then a selected rectangle.
private func extPenRect(_ style: UInt32, _ width: UInt32, _ brush: UInt32) throws -> MetafileStroke? {
    let pen = erecAt(95, 52, [(8, 1), (28, style), (32, width), (36, brush), (40, 0x0000_FF00)], [])
    let recs = [pen, erec(37, h32(1)), erec(43, cat([e32(0), e32(0), e32(10), e32(10)]))]
    return try pathSegs(item(parse(emf(recs, [0, 0, 0, 0], [0, 0, 0, 0])), 0)).2
}

@Test func emfExtPenCosmeticIsAHairlineAndNullBrushDrawsNothing() throws {
    // PS_COSMETIC widths are device pixels: a hairline, not one logical unit.
    #expect(try extPenRect(0, 1, 0) == S(C(0, 255, 0, 255), 0))
    // PS_GEOMETRIC (0x10000) keeps its logical width.
    #expect(try extPenRect(0x0001_0000, 4, 0) == S(C(0, 255, 0, 255), 4))
    // A BS_NULL brush draws no line.
    #expect(try extPenRect(0x0001_0000, 4, 1) == nil)
}

@Test func flipToleratesAShortPixelBuffer() {
    var img = Rgba(w: 2, h: 2, bottomUp: false, px: [UInt8](repeating: 1, count: 7))
    DIB.flip(&img, horizontal: true, vertical: true)
    #expect(img.px.count == 7)
    // Three rows held of four: only the rows present swap (0 with 2).
    img = Rgba(w: 1, h: 4, bottomUp: false, px: Array(0 ..< 12))
    DIB.flip(&img, horizontal: false, vertical: true)
    #expect(img.px == [8, 9, 10, 11, 4, 5, 6, 7, 0, 1, 2, 3])
}

/// deckcraft and WordCraft run this test with the same assertions; it runs under both crop rules.
@Test(arguments: [MetafileCropRule.deckcraft, .wordCraft])
func placeFitsTheFrameScalesStrokesAndDropsFarPaths(rule: MetafileCropRule) throws {
    let pic = MetafilePicture(width: 100, height: 50, items: [
        .path(segs: [.move(0, 0), .line(10, 10)], fill: nil, stroke: S(C(0, 0, 0, 255), 4), evenOdd: true, region: nil),
        .path(segs: [.move(0, 0), .line(2e6, 0)], fill: nil, stroke: nil, evenOdd: true, region: nil),
    ])
    let placed = pic.place(MetafileRect(0, 0, 200, 100), crop: .zero, rule: rule)
    #expect(placed.count == 1)
    guard case .path(_, _, let stroke, _, _)? = placed.first else { Issue.record("expected a path"); return }
    #expect(stroke?.width == 8)
}

/// deckcraft and WordCraft run this test with the same assertions; it runs under both crop rules.
@Test(arguments: [MetafileCropRule.deckcraft, .wordCraft])
func placeKeepsOnlyFiniteBoundedBitmapsWithArea(rule: MetafileCropRule) throws {
    func bmp(_ r: SIMD4<Float>) -> MetafileItem { .bitmap(rect: r, width: 1, height: 1, rgba: [0, 0, 0, 0], region: nil) }
    let pic = MetafilePicture(width: 100, height: 50, items: [
        bmp(SIMD4(.nan, 0, 10, 10)),
        bmp(SIMD4(0, 0, 0, 10)),
        bmp(SIMD4(0, 0, 2e6, 10)),
        bmp(SIMD4(0, 0, .infinity, 10)),
        bmp(SIMD4(10, 5, 10, 10)),
    ])
    let placed = pic.place(MetafileRect(0, 0, 200, 100), crop: .zero, rule: rule)
    #expect(placed.count == 1)
    guard case .bitmap(let index, let rect, _)? = placed.first else { Issue.record("expected a bitmap"); return }
    #expect(index == 4 && rect == MetafileRect(20, 10, 40, 30))
}

@Test func takePixelsReturnsOnlyDrawableBitmaps() {
    var ok = MetafileItem.bitmap(rect: .zero, width: 2, height: 1, rgba: [UInt8](repeating: 7, count: 8), region: nil)
    let taken = ok.takePixels()
    #expect(taken?.width == 2 && taken?.height == 1 && taken?.rgba == [UInt8](repeating: 7, count: 8))
    if case .bitmap(_, _, _, let rgba, _) = ok { #expect(rgba.isEmpty, "the pixels move out") } else { Issue.record("not a bitmap") }
    var short = MetafileItem.bitmap(rect: .zero, width: 2, height: 2, rgba: [UInt8](repeating: 0, count: 8), region: nil)
    #expect(short.takePixels() == nil)
    let side = Metafile.maxBitmapSide + 1
    var wide = MetafileItem.bitmap(rect: .zero, width: side, height: 1, rgba: [UInt8](repeating: 0, count: Int(side) * 4), region: nil)
    #expect(wide.takePixels() == nil)
    var path = MetafileItem.path(segs: [], fill: nil, stroke: nil, evenOdd: false, region: nil)
    #expect(path.takePixels() == nil)
    func pic(_ w: Float, _ h: Float) -> MetafilePicture { MetafilePicture(width: w, height: h, items: []) }
    #expect(pic(1, 2).hasSize)
    #expect(!pic(0, 2).hasSize && !pic(.nan, 2).hasSize && !pic(1, .infinity).hasSize)
}

/// The rectangle a WMF RECTANGLE record covers, from its path's corners.
func rectExtent(_ item: MetafileItem) throws -> (Float, Float, Float, Float) {
    let (segs, _, _, _) = try pathSegs(item)
    var (xs, ys): ([Float], [Float]) = ([], [])
    for s in segs {
        switch s {
        case .move(let x, let y), .line(let x, let y):
            xs.append(x)
            ys.append(y)
        default: break
        }
    }
    func lo(_ v: [Float]) -> Float { v.reduce(Float.greatestFiniteMagnitude) { $0.rustMin($1) } }
    func hi(_ v: [Float]) -> Float { v.reduce(-Float.greatestFiniteMagnitude) { $0.rustMax($1) } }
    return (lo(xs), lo(ys), hi(xs), hi(ys))
}

@Test func plainAnisotropicWmfWithoutAViewportFillsItsWindow() throws {
    // Anisotropic, window 200 x 100, no viewport (a logo strip saved without a placeable header): the window is
    // the target, not a 1 x 1 viewport that squeezes the picture to a point.
    let recs = [
        wrec(0x0103, h16(8)),
        wrec(0x020B, cat([h16(0), h16(0)])),
        wrec(0x020C, cat([h16(100), h16(200)])),
        wrec(0x041B, cat([h16(100), h16(200), h16(0), h16(0)])),
    ]
    let p = try parse(wmf(recs, nil))
    #expect((p.width, p.height) == (200, 100))
    let (x0, y0, x1, y1) = try rectExtent(item(p, 0))
    #expect(close(x0, 0) && close(y0, 0) && close(x1, 200) && close(y1, 100), "\(x0) \(y0) \(x1) \(y1)")
}

@Test func placeableWmfWindowRecordsReplaceTheBounds() throws {
    // The placeable bounds say 1440 square (72 points); the file then draws in a window centred on the origin, as
    // a coat of arms saved by a drawing program does. The window maps onto the 72-point target, so the drawing
    // fills it instead of being blown up around the bounds.
    let recs = [
        wrec(0x020C, cat([h16(2000), h16(2000)])),
        wrec(0x020B, cat([h16(-1000), h16(-1000)])),
        wrec(0x041B, cat([h16(1000), h16(1000), h16(-1000), h16(-1000)])),
    ]
    let p = try parse(wmf(recs, [238, 539, 1678, 1979]))
    #expect((p.width, p.height) == (72, 72))
    let (x0, y0, x1, y1) = try rectExtent(item(p, 0))
    #expect(close(x0, 0) && close(y0, 0) && close(x1, 72) && close(y1, 72), "\(x0) \(y0) \(x1) \(y1)")
}

@Test func placeableWmfKeepsItsTargetWhenTheWindowChangesShape() throws {
    // Bounds 600 x 300 (30 x 15 points), then a portrait window 100 x 200 for a bitmap-sized drawing: the drawing
    // still fills the target (Word stretches it to the picture's box).
    let recs = [wrec(0x0103, h16(8)), wrec(0x020C, cat([h16(200), h16(100)])), wrec(0x041B, cat([h16(200), h16(100), h16(0), h16(0)]))]
    let p = try parse(wmf(recs, [0, 0, 600, 300]))
    #expect((p.width, p.height) == (30, 15))
    let (x0, y0, x1, y1) = try rectExtent(item(p, 0))
    #expect(close(x0, 0) && close(y0, 0) && close(x1, 30) && close(y1, 15), "\(x0) \(y0) \(x1) \(y1)")
}

@Test func rop2NopDrawsNothingUntilTheModeChanges() throws {
    // A coat of arms that first draws its bounding rectangle with the R2_NOP mix mode (no output), then its shapes
    // with R2_COPYPEN. Restoring a saved state brings R2_NOP back.
    func rect(_ n: Int) -> [UInt8] { wrec(0x041B, cat([h16(n), h16(n), h16(0), h16(0)])) }
    let recs = [wrec(0x0104, h16(11)), rect(100), wrec(0x001E, []), wrec(0x0104, h16(13)), rect(50), wrec(0x0127, h16(-1)), rect(20)]
    let p = try parse(wmf(recs, [0, 0, 100, 100]))
    #expect(p.items.count == 1, "\(p.items)")
    let (_, _, x1, y1) = try rectExtent(item(p, 0))
    // 50 of 100 units in a 5-point picture.
    #expect(close(x1, 2.5) && close(y1, 2.5), "\(x1) \(y1)")
}

@Test func plainWmfTargetComesFromAWindowThatWasRead() throws {
    // A window record too short to read, then the real one: the target is the real window, not the 1 x 1 default
    // the short record left in place. A viewport origin set before it is kept.
    let recs = [
        wrec(0x0103, h16(8)),
        wrec(0x020D, cat([h16(0), h16(0)])),
        wrec(0x020C, []),
        wrec(0x020C, cat([h16(100), h16(200)])),
        wrec(0x041B, cat([h16(100), h16(200), h16(0), h16(0)])),
    ]
    let p = try parse(wmf(recs, nil))
    #expect((p.width, p.height) == (200, 100))
    let (x0, y0, x1, y1) = try rectExtent(item(p, 0))
    #expect(close(x0, 0) && close(y0, 0) && close(x1, 200) && close(y1, 100), "\(x0) \(y0) \(x1) \(y1)")
}

// MARK: - Text, pattern and hatch brushes, mix-mode idioms

/// META_CREATEFONTINDIRECT: height, width, escapement (and orientation), weight, the italic, underline, strike-out
/// and charset bytes, four precision bytes, then the NUL-terminated face.
func wfont(_ height: Int, _ weight: Int, _ flags: [UInt8], _ charset: UInt8, _ esc: Int, _ face: [UInt8]) -> [UInt8] {
    wrec(0x02FB, cat([h16(height), h16(0), h16(esc), h16(esc), h16(weight)]) + flags + [charset, 0, 0, 0, 0] + face + [0])
}

/// META_EXTTEXTOUT at (x, y): the rectangle when given, the string padded to a word, then `dx`.
func wtext(_ x: Int, _ y: Int, _ s: [UInt8], _ opts: Int, _ rect: [Int]?, _ dx: [Int]) -> [UInt8] {
    var v = cat([h16(y), h16(x), h16(s.count), h16(opts)])
    for c in rect ?? [] { v += h16(c) }
    v += s
    if s.count % 2 == 1 { v.append(0) }
    for d in dx { v += h16(d) }
    return wrec(0x0A32, v)
}

func b(_ s: String) -> [UInt8] { Array(s.utf8) }

/// A plain WMF whose 200 × 100 window maps one logical unit to one picture unit.
func wmf200(_ records: [[UInt8]]) throws -> MetafilePicture {
    try parse(wmf([wrec(0x020C, cat([h16(100), h16(200)]))] + records, nil))
}

func texts(_ p: MetafilePicture) -> [MetafileText] {
    p.items.compactMap { if case .text(let t) = $0 { t } else { nil } }
}

func firstText(_ p: MetafilePicture) throws -> MetafileText {
    guard let t = texts(p).first else {
        Issue.record("no text in \(p.items)")
        throw MissingItem()
    }
    return t
}

func close6(_ a: [Double], _ b: [Double]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { Swift.abs($0 - $1) < 1e-6 }
}

@Test func wmfTextReadsTheFontStringDxColourAndAlignment() throws {
    let recs = [
        wfont(-20, 700, [1, 1, 1], 0, 0, b("Arial")),
        wrec(0x012D, h16(0)),
        wrec(0x0209, h32(0x0000_00FF)),
        wrec(0x0102, h16(1)),
        wrec(0x012E, h16(24 | 6)),
        wtext(50, 60, b("Hi!"), 0, nil, [10, 8, 6]),
    ]
    let p = try wmf200(recs)
    #expect(texts(p).count == 1, "\(p.items)")
    let t = try firstText(p)
    #expect(t.text == "Hi!")
    #expect(t.dx == [10, 8, 6], "the dx array follows the word-padded odd string")
    #expect(t.font.family == "Arial")
    #expect(t.font.height == -20 && t.font.weight == 700 && t.font.italic && t.font.underline && t.font.strike)
    #expect(t.color == C(255, 0, 0, 255))
    #expect(t.background == nil, "TRANSPARENT background mode")
    #expect(t.hAlign == .center && t.vAlign == .baseline)
    #expect(close6(t.transform, [1, 0, 0, 1, 50, 60]), "\(t.transform)")
    #expect(t.clip == nil)
}

@Test func fontHeightSignAndDefaultStateAreKept() throws {
    // A positive height is the cell height; it stays positive for the renderer to resolve. Without SETTEXTALIGN
    // the reference point is the top left; without SETBKMODE the cell is filled white.
    let recs = [wfont(30, 400, [0, 0, 0], 0, 0, b("Times New Roman")), wrec(0x012D, h16(0)), wtext(5, 5, b("x"), 0, nil, [])]
    var t = try firstText(wmf200(recs))
    #expect(t.font.height == 30)
    #expect(t.font.family == "Times New Roman")
    #expect(t.hAlign == .left && t.vAlign == .top)
    #expect(t.background == C(255, 255, 255, 255))
    #expect(t.dx.isEmpty, "no dx array in the record")
    // Right and bottom.
    t = try firstText(wmf200([wrec(0x012E, h16(2 | 8)), wtext(5, 5, b("x"), 0, nil, [])]))
    #expect(t.hAlign == .right && t.vAlign == .bottom)
    #expect(t.font == MetafileFont(), "no font selected")
}

@Test func escapementTurnsTheBaselineCounterClockwise() throws {
    let recs = [wfont(-20, 400, [0, 0, 0], 0, 900, b("Arial")), wrec(0x012D, h16(0)), wtext(100, 90, b("Up"), 0, nil, [])]
    let t = try firstText(wmf200(recs))
    // Text x runs up the picture (0, -1); text y (down the glyphs) runs right (1, 0).
    #expect(close6(t.transform, [0, -1, 1, 0, 100, 90]), "\(t.transform)")
}

@Test func aYUpMappingMovesTextButDoesNotMirrorIt() throws {
    // Window 200 × -100 onto a 200 × 100 viewport: y goes up.
    let recs = [
        wrec(0x0103, h16(8)),
        wrec(0x020C, cat([h16(-100), h16(200)])),
        wrec(0x020E, cat([h16(100), h16(200)])),
        wtext(40, -30, b("A"), 0, nil, []),
    ]
    let t = try firstText(parse(wmf(recs, nil)))
    #expect(close6(t.transform, [1, 0, 0, 1, 40, 30]), "\(t.transform)")
}

@Test func updateCPStartsAtTheCurrentPositionAndMovesPastTheString() throws {
    let recs = [
        wrec(0x012E, h16(1)), wrec(0x0214, cat([h16(20), h16(10)])), wtext(0, 0, b("ab"), 0, nil, [5, 7]), wtext(0, 0, b("c"), 0, nil, [3]),
    ]
    let t = try texts(wmf200(recs))
    #expect(t.count == 2)
    guard t.count == 2 else { return }
    #expect(close6(t[0].transform, [1, 0, 0, 1, 10, 20]), "\(t[0].transform)")
    #expect(close6(t[1].transform, [1, 0, 0, 1, 22, 20]), "\(t[1].transform)")
}

@Test func etoOpaqueFillsTheRectangleAndEtoClippedClips() throws {
    let recs = [wrec(0x0201, h32(0x0000_FF00)), wtext(12, 30, b("ok"), 2 | 4, [10, 10, 60, 40], [])]
    let p = try wmf200(recs)
    #expect(p.items.count == 2, "\(p.items)")
    let (x0, y0, x1, y1) = try rectExtent(item(p, 0))
    #expect(close(x0, 10) && close(y0, 10) && close(x1, 60) && close(y1, 40))
    #expect(try pathSegs(item(p, 0)).1 == C(0, 255, 0, 255))
    let t = try firstText(p)
    #expect(t.clip == SIMD4(10, 10, 60, 40))
    #expect(t.background == C(0, 255, 0, 255))
}

@Test func characterSetsDecodeBytes() throws {
    func one(_ charset: UInt8, _ s: [UInt8]) throws -> String {
        try firstText(wmf200([wfont(-10, 400, [0, 0, 0], charset, 0, b("F")), wrec(0x012D, h16(0)), wtext(0, 0, s, 0, nil, [])])).text
    }
    #expect(try one(0, [0x41, 0x80, 0x93, 0x94, 0xE9]) == "A€“”é")
    #expect(try one(238, [0xB9, 0xE8, 0x9E, 0xA3]) == "ąčžŁ")
    #expect(try one(204, [0xC0, 0xFF, 0xA8]) == "АяЁ")
    #expect(try one(2, [0x6E, 0xA7]) == "\u{F06E}\u{F0A7}", "symbol fonts keep their codes in the private-use area")
    #expect(try one(0, [0x81]) == "\u{FFFD}", "an undefined byte")
    // A double-byte character set: a lead and trail byte become one blank with both advances.
    let recs = [wfont(-10, 400, [0, 0, 0], 128, 0, b("F")), wrec(0x012D, h16(0)), wtext(0, 0, [0x41, 0x82, 0xA0, 0x42], 0, nil, [1, 2, 3, 4])]
    let t = try firstText(wmf200(recs))
    #expect(t.text == "A B" && t.dx == [1, 5, 4])
}

@Test func wmfTextoutReadsItsStringAndPosition() throws {
    let v = h16(3) + b("abc\0") + cat([h16(40), h16(30)])
    let t = try firstText(wmf200([wrec(0x0521, v)]))
    #expect(t.text == "abc")
    #expect(close6(t.transform, [1, 0, 0, 1, 30, 40]), "\(t.transform)")
}

@Test func savedcRestoresTextColourAndFont() throws {
    let recs = [
        wfont(-10, 400, [0, 0, 0], 0, 0, b("One")),
        wrec(0x012D, h16(0)),
        wrec(0x0209, h32(0x0000_00FF)),
        wrec(0x001E, []),
        wfont(-10, 400, [0, 0, 0], 0, 0, b("Two")),
        wrec(0x012D, h16(1)),
        wrec(0x0209, h32(0x00FF_0000)),
        wrec(0x0127, h16(-1)),
        wtext(0, 0, b("x"), 0, nil, []),
    ]
    let t = try firstText(wmf200(recs))
    #expect(t.font.family == "One" && t.color == C(255, 0, 0, 255))
}

/// EMR_EXTCREATEFONTINDIRECTW in slot 1: LogFont at 12, face at 40.
func efont(_ height: Int, _ esc: Int, _ weight: Int, _ italic: UInt8, _ charset: UInt8, _ face: String) -> [UInt8] {
    var v = cat([h32(1), e32(height), e32(0), e32(esc), e32(esc), e32(weight)])
    v += [italic, 0, 0, charset, 0, 0, 0, 0]
    var name = face.utf16.flatMap(u16b)
    name += [UInt8](repeating: 0, count: Swift.max(64 - name.count, 0))
    v += name.prefix(64)
    return erec(82, v)
}

func up4(_ n: Int) -> Int { (n + 3) / 4 * 4 }

/// EMR_EXTTEXTOUTW (or A) at (x, y) with options, the rectangle (absent under ETO_NO_RECT), the string at 76 and
/// the dx array after it.
func etext(_ wide: Bool, _ x: Int, _ y: Int, _ units: [UInt16], _ opts: UInt32, _ dx: [Int]) -> [UInt8] {
    let noRect = opts & 0x100 != 0
    let sOff = noRect ? 60 : 76
    let s: [UInt8] = wide ? units.flatMap(u16b) : units.map { UInt8(truncatingIfNeeded: $0) }
    let dxOff = up4(sOff + s.count)
    let len = dxOff + dx.count * 4
    var f: [(Int, UInt32)] = [
        (24, 1), (36, UInt32(bitPattern: Int32(x))), (40, UInt32(bitPattern: Int32(y))), (44, UInt32(units.count)), (48, UInt32(sOff)), (52, opts),
    ]
    f.append((noRect ? 56 : 72, dx.isEmpty ? 0 : UInt32(dxOff)))
    return erecAt(wide ? 84 : 83, up4(len), f, [(sOff, s), (dxOff, dx.flatMap(e32))])
}

@Test func emfExttextoutwReadsUTF16DxAndTheFont() throws {
    let recs = [
        efont(24, 0, 400, 1, 0, "Segoe UI"),
        erec(37, h32(1)),
        erec(22, h32(0x18 | 2)),
        erec(24, h32(0x0000_FF00)),
        erec(18, h32(1)),
        etext(true, 100, 50, [0x41, 0xD83D, 0xDE00], 0, [10, 6, 0]),
    ]
    let p = try parse(emf(recs, [0, 0, 200, 100], [0, 0, 5000, 2500]))
    #expect(texts(p).count == 1, "\(p.items)")
    let t = try firstText(p)
    #expect(t.text == "A\u{1F600}")
    #expect(t.dx == [10, 6], "a surrogate pair takes both advances")
    #expect(t.font.family == "Segoe UI" && t.font.height == 24 && t.font.italic)
    #expect(t.hAlign == .right && t.vAlign == .baseline && t.color == C(0, 255, 0, 255) && t.background == nil)
    // Upright, uniformly scaled.
    let m = t.transform
    #expect(m[0] > 0 && m[3] > 0 && Swift.abs(m[1]) < 1e-9 && Swift.abs(m[2]) < 1e-9 && Swift.abs(m[0] - m[3]) < 1e-9, "\(m)")
}

@Test func emfTextOptionsPdyNoRectAnsiAndGlyphIndices() throws {
    // ETO_PDY: (dx, dy) pairs, of which dx is used. ETO_NO_RECT moves the dx offset to 56.
    var p = try parse(emf([etext(true, 0, 0, [0x61, 0x62], 0x2000 | 0x100, [7, 1, 9, 2])], [0, 0, 200, 100], [0, 0, 5000, 2500]))
    #expect(try firstText(p).dx == [7, 9])
    // EXTTEXTOUTA decodes through the font's charset.
    let recs = [efont(-10, 0, 400, 0, 238, "F"), erec(37, h32(1)), etext(false, 0, 0, [0xB9], 0, [])]
    p = try parse(emf(recs, [0, 0, 200, 100], [0, 0, 5000, 2500]))
    #expect(try firstText(p).text == "ą")
    // Glyph indices name glyphs of a font we cannot match: left out.
    p = try parse(emf([etext(true, 0, 0, [5, 6], 0x10, [])], [0, 0, 200, 100], [0, 0, 5000, 2500]))
    #expect(texts(p).isEmpty)
}

@Test func emfSmalltextoutReads8BitAnd16BitStrings() throws {
    // x, y, count, options, mode, scales, (no bounds under ETO_NO_RECT), characters.
    func small(_ opts: UInt32, _ chars: [UInt8]) -> [UInt8] {
        erec(108, cat([e32(3), e32(4), h32(2), h32(opts), h32(1), h32(0), h32(0)]) + chars)
    }
    var p = try parse(emf([small(0x100 | 0x200, b("hi"))], [0, 0, 200, 100], [0, 0, 5000, 2500]))
    #expect(try firstText(p).text == "hi")
    p = try parse(emf([small(0x100, [0x6F, 0, 0x6B, 0])], [0, 0, 200, 100], [0, 0, 5000, 2500]))
    #expect(try firstText(p).text == "ok")
}

/// An 8 × 8 one-bit DIB (palette white, black; stored bottom-up): `rows` top to bottom.
func monoDib(_ rows: [UInt8]) -> [UInt8] {
    var v = infoHeader(8, 8, 1, 32) + [255, 255, 255, 0, 0, 0, 0, 0]
    for r in rows.reversed() { v += [r, 0, 0, 0] }
    return v
}

func patternOf(_ item: MetafileItem) throws -> MetafileTile {
    guard case .pattern(_, _, let tile, _) = item else {
        Issue.record("expected a pattern fill: \(item)")
        throw NotAPath()
    }
    return tile
}

/// Pixel (x, y) of a tile.
func tilePx(_ t: MetafileTile, _ x: Int, _ y: Int) -> MetafileColor {
    let o = (y * Int(t.width) + x) * 4
    return MetafileColor(t.rgba[o], t.rgba[o + 1], t.rgba[o + 2], t.rgba[o + 3])
}

@Test func wmfDibPatternBrushPaintsItsRowsTopDown() throws {
    let brush = wrec(0x0142, cat([h16(5), h16(0), monoDib([0xFF, 0x80, 0, 0, 0, 0, 0, 0x01])]))
    let recs = [
        brush,
        // A pen after the brush: the brush took handle 0.
        wrec(0x02FA, cat([h16(0), h16(1), h16(0), h32(0x0000_00FF)])),
        wrec(0x012D, h16(0)),
        wrec(0x012D, h16(1)),
        wrec(0x041B, cat([h16(720), h16(1440), h16(0), h16(0)])),
    ]
    let p = try parse(wmf(recs, [0, 0, 1440, 720]))
    #expect(p.items.count == 2, "the tile fill and the outline: \(p.items)")
    let t = try patternOf(item(p, 0))
    #expect(t.width == 8 && t.height == 8)
    for x in 0 ..< 8 { #expect(tilePx(t, x, 0) == C(0, 0, 0, 255), "top row is set: black") }
    #expect(tilePx(t, 0, 1) == C(0, 0, 0, 255))
    #expect(tilePx(t, 1, 1) == C(255, 255, 255, 255))
    #expect(tilePx(t, 7, 7) == C(0, 0, 0, 255))
    #expect(tilePx(t, 0, 7) == C(255, 255, 255, 255))
    // 96-dpi pixels of a picture in points, laid from the picture's corner.
    #expect(close(t.cell[0], 0.75) && close(t.cell[1], 0.75) && t.origin == SIMD2(0, 0), "\(t.cell) \(t.origin)")
    #expect(try pathSegs(item(p, 1)).2?.color == C(255, 0, 0, 255))
}

@Test func hatchBrushesDrawLinesOverTheBackgroundMode() throws {
    func hatch(_ style: Int) -> [UInt8] { wrec(0x02FC, cat([h16(2), h32(0x00FF_0000), h16(style)])) }
    let rect = wrec(0x041B, cat([h16(50), h16(50), h16(0), h16(0)]))
    // HS_CROSS over a transparent background.
    var p = try wmf200([hatch(4), wrec(0x012D, h16(0)), wrec(0x0102, h16(1)), rect])
    var t = try patternOf(item(p, 0))
    let blue = C(0, 0, 255, 255)
    #expect(tilePx(t, 3, 7) == blue && tilePx(t, 7, 3) == blue)
    #expect(tilePx(t, 3, 3)[3] == 0, "gaps are transparent")
    // HS_BDIAGONAL over the opaque white background.
    p = try wmf200([hatch(3), wrec(0x012D, h16(0)), rect])
    t = try patternOf(item(p, 0))
    #expect(tilePx(t, 0, 7) == blue && tilePx(t, 7, 0) == blue)
    #expect(tilePx(t, 0, 0) == C(255, 255, 255, 255))
    // An unknown hatch style draws no fill.
    p = try wmf200([hatch(9), wrec(0x012D, h16(0)), rect])
    #expect(p.items.allSatisfy { if case .pattern = $0 { false } else { true } }, "\(p.items)")
}

@Test func xorMaskXorDrawsThePatternInTheXorColour() throws {
    // The see-through shadow: XOR a grey polygon, AND a checker pattern, XOR the polygon again.
    let square = wrec(0x0324, cat([h16(4), h16(0), h16(0), h16(40), h16(0), h16(40), h16(40), h16(0), h16(40)]))
    let recs = [
        wrec(0x0104, h16(7)),
        wrec(0x02FC, cat([h16(0), h32(0x0080_8080), h16(0)])),
        wrec(0x012D, h16(0)),
        square,
        wrec(0x0104, h16(9)),
        wrec(0x0142, cat([h16(5), h16(0), monoDib([0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA])])),
        wrec(0x012D, h16(1)),
        wrec(0x041B, cat([h16(40), h16(40), h16(0), h16(0)])),
        wrec(0x0104, h16(7)),
        wrec(0x012D, h16(0)),
        square,
    ]
    let p = try wmf200(recs)
    #expect(p.items.count == 2, "only the AND pattern (and its outline) draw: \(p.items)")
    let t = try patternOf(item(p, 0))
    // 0x55 = 0101 0101: white, black, …
    #expect(tilePx(t, 0, 0)[3] == 0, "white keeps what is below")
    #expect(tilePx(t, 1, 0) == C(128, 128, 128, 255), "black takes the XOR colour")
}

@Test func patbltFillsWithTheBrush() throws {
    func patblt(_ rop: UInt32) -> [UInt8] { wrec(0x061D, cat([h32(rop), h16(30), h16(40), h16(10), h16(20)])) }
    let recs = [wrec(0x02FC, cat([h16(0), h32(0x00FF_0000), h16(0)])), wrec(0x012D, h16(0)), patblt(0x00F0_0021), patblt(0x0055_0009)]
    let p = try wmf200(recs)
    #expect(p.items.count == 1, "DSTINVERT draws nothing: \(p.items)")
    let (x0, y0, x1, y1) = try rectExtent(item(p, 0))
    #expect(close(x0, 20) && close(y0, 10) && close(x1, 60) && close(y1, 40), "\(x0) \(y0) \(x1) \(y1)")
    #expect(try pathSegs(item(p, 0)).1 == C(0, 0, 255, 255))
}

@Test func emfDibPatternAndMonoBrushes() throws {
    let dib = monoDib([UInt8](repeating: 0xF0, count: 8))
    let (info, bits) = (Array(dib[..<48]), Array(dib[48...]))
    func brush(_ typ: UInt32) -> [UInt8] {
        let f: [(Int, UInt32)] = [(8, 1), (12, 0), (16, 32), (20, UInt32(info.count)), (24, 32 + UInt32(info.count)), (28, UInt32(bits.count))]
        return erecAt(typ, 32 + dib.count, f, [(32, info), (32 + info.count, bits)])
    }
    let rect = erec(43, cat([e32(0), e32(0), e32(40), e32(40)]))
    let nullPen = erec(37, h32(0x8000_0008))
    var p = try parse(emf([brush(94), erec(37, h32(1)), nullPen, rect], [0, 0, 200, 100], [0, 0, 5000, 2500]))
    var t = try patternOf(item(p, 0))
    #expect(tilePx(t, 0, 0) == C(0, 0, 0, 255) && tilePx(t, 7, 0) == C(255, 255, 255, 255))
    // A mono brush paints in the text colour (red) and the background colour (green).
    let recs = [erec(24, h32(0xFF)), erec(25, h32(0xFF00)), brush(93), erec(37, h32(1)), nullPen, rect]
    p = try parse(emf(recs, [0, 0, 200, 100], [0, 0, 5000, 2500]))
    t = try patternOf(item(p, 0))
    #expect(tilePx(t, 0, 0) == C(255, 0, 0, 255) && tilePx(t, 7, 0) == C(0, 255, 0, 255))
}
