// WMF and EMF records into the model: shapes, mapping, bitmaps, caps and hostile input. Port of deckcraft
// crates/metafile/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
@testable import CNMetafile
import Testing

@Test func wmfRectangleWithSolidBrush() throws {
    let recs = [
        wrec(0x02FC, cat([h16(0), h32(0x0000_00FF), h16(0)])),
        wrec(0x012D, h16(0)),
        wrec(0x041B, cat([h16(70), h16(110), h16(20), h16(10)])),
    ]
    let p = try parse(wmf(recs, nil))
    #expect((p.width, p.height) == (100, 50))
    #expect(p.items.count == 1)
    let (segs, fill, stroke, evenOdd) = try pathSegs(item(p, 0))
    #expect(segs == [.move(0, 0), .line(100, 0), .line(100, 50), .line(0, 50), .close])
    #expect(fill == C(255, 0, 0, 255))
    #expect(stroke == S(C(0, 0, 0, 255), 0))
    #expect(evenOdd)
}

@Test func wmfPolylineWithPen() throws {
    let recs = [
        wrec(0x02FA, cat([h16(0), h16(4), h16(0), h32(0x0000_FF00)])),
        wrec(0x012D, h16(0)),
        wrec(0x0325, cat([h16(3), h16(0), h16(0), h16(50), h16(0), h16(50), h16(40)])),
    ]
    let p = try parse(wmf(recs, nil))
    #expect((p.width, p.height) == (50, 40))
    let (segs, fill, stroke, _) = try pathSegs(item(p, 0))
    #expect(segs == [.move(0, 0), .line(50, 0), .line(50, 40)])
    #expect(fill == nil)
    #expect(stroke == S(C(0, 255, 0, 255), 4))
}

@Test func wmfPolygonFillRuleFollowsPolyfillmode() throws {
    let square = cat([h16(4), h16(0), h16(0), h16(10), h16(0), h16(10), h16(10), h16(0), h16(10)])
    let winding = [wrec(0x0106, h16(2)), wrec(0x0324, square)]
    var p = try parse(wmf(winding, nil))
    #expect(try !pathSegs(item(p, 0)).3, "WINDING fills use the nonzero rule")
    p = try parse(wmf([wrec(0x0324, square)], nil))
    let (segs, fill, _, evenOdd) = try pathSegs(item(p, 0))
    #expect(evenOdd, "default ALTERNATE is even-odd")
    #expect(fill == C(255, 255, 255, 255))
    #expect(segs.last == .close)
}

@Test func wmfStretchdibFlipsBottomUpRows() throws {
    let params = cat([h32(0x00CC_0020), h16(0), h16(2), h16(2), h16(0), h16(0), h16(10), h16(20), h16(0), h16(0), dib24BottomUp()])
    let p = try parse(wmf([wrec(0x0F43, params)], nil))
    #expect((p.width, p.height) == (20, 10))
    let b = try bitmap(item(p, 0))
    #expect(b.rect == SIMD4(0, 0, 20, 10))
    #expect((b.width, b.height) == (2, 2))
    #expect(b.rgba == dib24RGBA)
}

@Test func wmfMappingWindowAndViewport() throws {
    let recs = [
        wrec(0x0103, h16(8)),
        wrec(0x020B, cat([h16(100), h16(100)])),
        wrec(0x020C, cat([h16(50), h16(50)])),
        wrec(0x020E, cat([h16(100), h16(100)])),
        wrec(0x0214, cat([h16(100), h16(100)])),
        wrec(0x0213, cat([h16(150), h16(150)])),
    ]
    let p = try parse(wmf(recs, nil))
    #expect((p.width, p.height) == (100, 100))
    let (segs, fill, stroke, _) = try pathSegs(item(p, 0))
    #expect(segs == [.move(0, 0), .line(100, 100)])
    #expect(fill == nil)
    #expect(stroke == S(C(0, 0, 0, 255), 0))
}

@Test func wmfPlaceableHeaderSetsFrameInPoints() throws {
    let p = try parse(wmf([wrec(0x041B, cat([h16(1440), h16(2880), h16(0), h16(0)]))], [0, 0, 2880, 1440]))
    #expect((p.width, p.height) == (144, 72))
}

@Test func emfStretchdibitsFlipsAndFitsFrame() throws {
    var payload = [UInt8](repeating: 0, count: 16)
    payload += cat([e32(0), e32(0), e32(0), e32(0), e32(2), e32(2), e32(80), e32(40), e32(120), e32(16), e32(0), e32(0x00CC_0020), e32(100), e32(50)])
    payload += infoHeader(2, 2, 24, 16)
    payload += dib24BottomUp()[40...]
    let rec = erec(81, payload)
    // A 25 x 12.5 mm frame is 70.87 x 35.43 points; the bitmap fills the whole frame.
    let p = try parse(emf([rec], [0, 0, 100, 50], [0, 0, 2500, 1250]))
    let (w, h) = (2500.0 * 72.0 / 2540.0, 1250.0 * 72.0 / 2540.0)
    #expect(close(p.width, Float(w)) && close(p.height, Float(h)))
    let b = try bitmap(item(p, 0))
    #expect(zip([b.rect[0], b.rect[1], b.rect[2], b.rect[3]], [0, 0, w, h]).allSatisfy { close($0, Float($1)) })
    #expect((b.width, b.height) == (2, 2))
    #expect(b.rgba == dib24RGBA)
}

@Test func emfWorldTransformScalesGeometry() throws {
    let recs = [erec(35, xformBytes([2, 0, 0, 2, 0, 0])), erec(27, cat([e32(0), e32(0)])), erec(54, cat([e32(10), e32(5)]))]
    let p = try parse(emf(recs, [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect((p.width, p.height) == (20, 10))
    let (segs, fill, stroke, _) = try pathSegs(item(p, 0))
    #expect(segs == [.move(0, 0), .line(20, 10)])
    #expect(fill == nil)
    #expect(stroke == S(C(0, 0, 0, 255), 0))
}

@Test func emfEllipseIsFourCubicsBackToStart() throws {
    let p = try parse(emf([erec(42, cat([e32(0), e32(0), e32(40), e32(20)]))], [0, 0, 0, 0], [0, 0, 0, 0]))
    let (segs, fill, _, _) = try pathSegs(item(p, 0))
    #expect(segs.count == 6)
    #expect(try seg(segs, 0) == .move(40, 10))
    guard case .cubic(_, _, _, _, let x, let y) = try seg(segs, 4) else { Issue.record("\(segs)"); return }
    #expect(close(x, 40) && close(y, 10))
    #expect(try seg(segs, 5) == .close)
    #expect(fill == C(255, 255, 255, 255))
}

@Test func emfPathBracketStrokeandfillUsesStockBlackBrush() throws {
    let recs = [
        erec(59, []),
        erec(27, cat([e32(0), e32(0)])),
        erec(54, cat([e32(10), e32(0)])),
        erec(54, cat([e32(10), e32(10)])),
        erec(61, []),
        erec(60, []),
        erec(37, h32(0x8000_0004)),
        erec(63, [UInt8](repeating: 0, count: 16)),
    ]
    let p = try parse(emf(recs, [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(p.items.count == 1)
    let (segs, fill, stroke, _) = try pathSegs(item(p, 0))
    #expect(segs == [.move(0, 0), .line(10, 0), .line(10, 10), .close])
    #expect(fill == C(0, 0, 0, 255))
    #expect(stroke == S(C(0, 0, 0, 255), 0))
}

@Test func itemCapStopsTheParseAndKeepsTheRest() throws {
    let rect = wrec(0x041B, cat([h16(10), h16(10), h16(0), h16(0)]))
    let recs = [[UInt8]](repeating: rect, count: Metafile.maxItems + 10)
    let p = try parse(wmf(recs, nil))
    #expect(p.items.count == Metafile.maxItems)
}

@Test func detectionAndGarbage() {
    let w = wmf([wrec(0x041B, cat([h16(1), h16(1), h16(0), h16(0)]))], nil)
    let e = emf([erec(42, cat([e32(0), e32(0), e32(4), e32(4)]))], [0, 0, 0, 0], [0, 0, 0, 0])
    #expect(isMetafile(w))
    #expect(isMetafile(e))
    let garbage = Array("hello world, not a metafile".utf8)
    #expect(!isMetafile(garbage))
    #expect(throws: MetafileError.notMetafile) { try parse(garbage) }
    #expect(throws: MetafileError.self) { try parse([]) }
}

@Test func truncatedRandomAndMutatedInputsNeverPanic() {
    let rect = wrec(0x041B, cat([h16(10), h16(10), h16(0), h16(0)]))
    let wfile = wmf(
        [
            wrec(0x02FC, cat([h16(0), h32(0xFF), h16(0)])),
            wrec(0x012D, h16(0)),
            rect,
            wrec(0x0325, cat([h16(2), h16(0), h16(0), h16(5), h16(5)])),
        ],
        [0, 0, 20, 10]
    )
    var dibRecord = cat([h32(0x00CC_0020), h16(0), h16(2), h16(2), h16(0), h16(0), h16(10), h16(20), h16(0), h16(0)])
    dibRecord += dib24BottomUp()
    _ = dibRecord
    var payload = [UInt8](repeating: 0, count: 16)
    payload += cat([e32(0), e32(0), e32(0), e32(0), e32(2), e32(2), e32(80), e32(40), e32(120), e32(16), e32(0), e32(0), e32(20), e32(10)])
    payload += infoHeader(2, 2, 24, 16)
    payload += dib24BottomUp()[40...]
    let efile = emf(
        [
            erec(59, []),
            erec(27, cat([e32(0), e32(0)])),
            erec(54, cat([e32(9), e32(9)])),
            erec(61, []),
            erec(60, []),
            erec(63, [UInt8](repeating: 0, count: 16)),
            erec(81, payload),
            erec(86, cat([h32(4), h16(0), h16(0), h16(9), h16(9), h16(0), h16(9)])),
        ],
        [0, 0, 20, 10],
        [0, 0, 2540, 1270]
    )
    for file in [wfile, efile] {
        for n in 0 ... file.count {
            let prefix = Array(file[..<n])
            _ = try? parse(prefix)
            _ = isMetafile(prefix)
        }
    }
    var rng = Lcg(0x2545_F491_4F6C_DD1D)
    for _ in 0 ..< 3000 {
        let len = Int(rng.rnd() % 400)
        let buf = (0 ..< len).map { _ in UInt8(truncatingIfNeeded: rng.rnd()) }
        _ = try? parse(buf)
    }
    for i in 0 ..< 1500 {
        var buf = i % 2 == 0 ? efile : wfile
        for _ in 0 ..< 8 {
            let at = Int(rng.rnd()) % buf.count
            buf[at] = UInt8(truncatingIfNeeded: rng.rnd())
        }
        _ = try? parse(buf)
    }
    for i in 0 ..< 500 {
        var buf = i % 2 == 0 ? efile : wfile
        let at = Int(rng.rnd()) % buf.count
        for k in at ..< buf.count { buf[k] = 0xFF }
        _ = try? parse(buf)
    }
}

@Test func wmfStockNullBrushBy16BitHandleHasNoFill() throws {
    // SELECTOBJECT with 0x8005 is the NULL_BRUSH stock object (0x8000 | 5), so the rectangle is outline only.
    let recs = [wrec(0x012D, h16(0x8005)), wrec(0x041B, cat([h16(70), h16(110), h16(20), h16(10)]))]
    let p = try parse(wmf(recs, nil))
    let (_, fill, stroke, _) = try pathSegs(item(p, 0))
    #expect(fill == nil)
    #expect(stroke == S(C(0, 0, 0, 255), 0))
}

@Test func emfFrameComesFromRclframeNotDeviceBounds() throws {
    // Bounds cover only the left half of the 25 x 12.5 mm frame (device units are 0.04 per 0.01 mm), so a
    // rectangle from x = 0 to 50 px ends at half the picture width.
    let rec = erec(43, cat([e32(0), e32(0), e32(50), e32(25)]))
    let p = try parse(emf([rec], [0, 0, 50, 25], [0, 0, 2500, 1250]))
    let w = 2500.0 * 72.0 / 2540.0
    #expect(close(p.width, Float(w)) && close(p.height, Float(1250.0 * 72.0 / 2540.0)))
    let (segs, _, _, _) = try pathSegs(item(p, 0))
    guard case .line(let x, _) = try seg(segs, 1) else { Issue.record("\(segs)"); return }
    #expect(close(x, Float(w / 2)), "\(segs)")
}

@Test func emfBoundsStandInWhenTheFrameIsEmpty() throws {
    let rec = erec(43, cat([e32(0), e32(0), e32(50), e32(25)]))
    let p = try parse(emf([rec], [0, 0, 50, 25], [0, 0, 0, 0]))
    #expect((p.width, p.height) == (50, 25))
}

@Test func wmfPlaceableBoundsGoThroughTheWindowMapping() throws {
    // Logical bounds 200 x 100 at 1440 per inch are 10 x 5 points; the window is 2:1 onto the viewport, so the
    // frame is 100 x 50 device units and the rectangle fills it.
    let recs = [
        wrec(0x0103, h16(8)),
        wrec(0x020C, cat([h16(100), h16(200)])),
        wrec(0x020E, cat([h16(50), h16(100)])),
        wrec(0x041B, cat([h16(100), h16(200), h16(0), h16(0)])),
    ]
    let p = try parse(wmf(recs, [0, 0, 200, 100]))
    #expect((p.width, p.height) == (10, 5))
    let (segs, _, _, _) = try pathSegs(item(p, 0))
    #expect(segs.contains { if case .line(let x, let y) = $0 { close(x, 10) && close(y, 5) } else { false } }, "\(segs)")
}

@Test func wmfStretchdibClippedSourceKeepsItsPlace() throws {
    // Source x from -1 for 2 columns: only column 0 is in the bitmap, so it fills the right half of the
    // destination and the picture keeps the original 20-unit width scale.
    let params = cat([h32(0x00CC_0020), h16(0), h16(2), h16(2), h16(0), h16(-1), h16(10), h16(20), h16(0), h16(0), dib24BottomUp()])
    let p = try parse(wmf([wrec(0x0F43, params)], [0, 0, 20, 10]))
    let b = try bitmap(item(p, 0))
    // Placeable units are points: 20 units at 1440 per inch are 1 point, so the right column is 0.5 pt wide.
    #expect(b.rect == SIMD4(0.5, 0, 0.5, 0.5))
    #expect((b.width, b.height) == (1, 2))
    #expect(b.rgba == [255, 0, 0, 255, 0, 0, 255, 255])
}

@Test func wmfNegativeDestinationWidthMirrorsTheBitmap() throws {
    let params = cat([h32(0x00CC_0020), h16(0), h16(2), h16(2), h16(0), h16(0), h16(10), h16(-20), h16(0), h16(0), dib24BottomUp()])
    // Frame from the placeable bounds (-20, 0)-(0, 10): the mirrored bitmap fills it.
    let p = try parse(wmf([wrec(0x0F43, params)], [-20, 0, 0, 10]))
    let b = try bitmap(item(p, 0))
    #expect(b.rect == SIMD4(0, 0, 1, 0.5))
    #expect(Array(b.rgba.prefix(8)) == [255, 255, 255, 255, 255, 0, 0, 255])
}

@Test func emfBlacknessBitbltFillsBlackWithoutASource() throws {
    var payload = [UInt8](repeating: 0, count: 16)
    payload += cat([e32(10), e32(20), e32(30), e32(40), e32(0x0000_0042)])
    let p = try parse(emf([erec(76, payload)], [0, 0, 0, 0], [0, 0, 0, 0]))
    let (segs, fill, stroke, _) = try pathSegs(item(p, 0))
    #expect(fill == C(0, 0, 0, 255))
    #expect(stroke == nil)
    #expect(segs.count == 5)
}

@Test func emfSavedcPastTheStackCapStopsTheParse() throws {
    var recs = [[UInt8]](repeating: erec(33, []), count: Metafile.maxStack + 1)
    recs.append(erec(43, cat([e32(0), e32(0), e32(10), e32(10)])))
    let p = try parse(emf(recs, [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(p.items.isEmpty, "records after the cap must not be drawn")
}

@Test func canvasStopsAtTheByteBudget() {
    // Two 128 MB bitmaps fit the budget; the third would exceed it and stops the canvas.
    var cv = Canvas()
    func big() -> Rgba { Rgba(w: 1, h: 1, bottomUp: false, px: [UInt8](repeating: 0, count: Metafile.maxBytes / 2)) }
    cv.bitmap(R4(0, 0, 1, 1), big())
    cv.bitmap(R4(0, 0, 1, 1), big())
    #expect(!cv.full)
    cv.bitmap(R4(0, 0, 1, 1), big())
    #expect(cv.full)
    #expect(cv.items.count == 2)
}

@Test func oversizedDibHeaderSizeIsRejectedWithoutOverflow() throws {
    var info = infoHeader(2, 2, 24, 16)
    put(&info, 0, h32(0xFFFF_FFF0))
    let params = cat([h32(0x00CC_0020), h16(0), h16(2), h16(2), h16(0), h16(0), h16(10), h16(20), h16(0), h16(0), info])
    let p = try parse(wmf([wrec(0x0F43, params)], nil))
    #expect(p.items.isEmpty)
}

@Test func wmfFontTakesAnObjectSlotSoHandlesLineUp() throws {
    // The font is handle 0, so the pen created after it is handle 1.
    let recs = [
        wrec(0x02FB, [UInt8](repeating: 0, count: 18)),
        wrec(0x02FA, cat([h16(0), h16(4), h16(0), h32(0x0000_FF00)])),
        wrec(0x012D, h16(1)),
        wrec(0x0325, cat([h16(2), h16(0), h16(0), h16(50), h16(0), h16(50)])),
    ]
    let p = try parse(wmf(recs, nil))
    let (_, _, stroke, _) = try pathSegs(item(p, 0))
    #expect(stroke == S(C(0, 255, 0, 255), 4))
}

@Test func emfPolybeziertoContinuesTheOpenPath() throws {
    // BEGINPATH, MOVETO a, LINETO b, POLYBEZIERTO16, CLOSEFIGURE, FILLPATH: one closed figure from a.
    var bezier = [UInt8](repeating: 0, count: 16)
    bezier += cat([e32(3), h16(10), h16(10), h16(20), h16(10), h16(20), h16(0)])
    let recs = [
        erec(59, []),
        erec(27, cat([e32(0), e32(0)])),
        erec(54, cat([e32(10), e32(0)])),
        erec(88, bezier),
        erec(61, []),
        erec(62, [UInt8](repeating: 0, count: 16)),
    ]
    let p = try parse(emf(recs, [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(p.items.count == 1)
    let (segs, fill, _, _) = try pathSegs(item(p, 0))
    #expect(segs == [.move(0, 0), .line(10, 0), .cubic(10, 10, 20, 10, 20, 0), .close])
    #expect(fill == C(255, 255, 255, 255))
}

@Test func emfPolybezierStartsItsOwnFigureAndKeepsTheCurrentPoint() throws {
    // POLYBEZIER (2) starts at its first point; the LINETO after it still starts at the MOVETO point.
    var bezier = [UInt8](repeating: 0, count: 16)
    bezier += cat([e32(4), e32(0), e32(0), e32(5), e32(5), e32(10), e32(5), e32(10), e32(0)])
    let recs = [erec(27, cat([e32(3), e32(3)])), erec(2, bezier), erec(54, cat([e32(50), e32(50)]))]
    let p = try parse(emf(recs, [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(p.items.count == 2)
    #expect(try seg(pathSegs(item(p, 0)).0, 0) == .move(0, 0))
    #expect(try pathSegs(item(p, 1)).0 == [.move(3, 3), .line(50, 50)])
}

@Test func hairlinePenStaysZeroUnderAnAnisotropicWindow() throws {
    // Window 2000 x 2000 onto a 1 x 1 viewport: a cosmetic pen must not become one device unit wide.
    let recs = [
        wrec(0x0103, h16(8)),
        wrec(0x020C, cat([h16(2000), h16(2000)])),
        wrec(0x020E, cat([h16(1), h16(1)])),
        wrec(0x0214, cat([h16(0), h16(0)])),
        wrec(0x0213, cat([h16(2000), h16(2000)])),
    ]
    let p = try parse(wmf(recs, nil))
    #expect((p.width, p.height) == (1, 1))
    let (segs, _, stroke, _) = try pathSegs(item(p, 0))
    #expect(segs.last == .line(1, 1))
    #expect(stroke == S(C(0, 0, 0, 255), 0))
}

@Test func nullPenIsRecognisedUnderExtraStyleBits() throws {
    // Pen style 0x105: PS_NULL (5) with a flag above the style nibble still draws no outline.
    let pen = erecAt(38, 28, [(8, 0), (12, 0x105), (16, 1), (24, 0)], [])
    let recs = [pen, erec(37, h32(0)), erec(43, cat([e32(0), e32(0), e32(10), e32(10)]))]
    let p = try parse(emf(recs, [0, 0, 0, 0], [0, 0, 0, 0]))
    let (_, fill, stroke, _) = try pathSegs(item(p, 0))
    #expect(fill == C(255, 255, 255, 255))
    #expect(stroke == nil)
}

@Test func metricMapModeFlipsYAndScalesToDevicePixelsEMF() throws {
    // LOMETRIC is 0.1 mm per unit; the header maps 4 device pixels to 1 mm. Points go y-up, so the drawing lies
    // below its origin and the picture frame moves up to its top.
    let recs = [erec(17, h32(2)), erec(27, cat([e32(0), e32(0)])), erec(54, cat([e32(100), e32(50)]))]
    let p = try parse(emf(recs, [0, 0, 0, 0], [0, 0, 0, 0]))
    let (segs, _, _, _) = try pathSegs(item(p, 0))
    #expect(try closeSeg(seg(segs, 0), .move(0, 20)) && closeSeg(seg(segs, 1), .line(40, 0)), "\(segs)")
}

@Test func metricMapModeUses96DpiForWMF() throws {
    let recs = [wrec(0x0103, h16(2)), wrec(0x0214, cat([h16(0), h16(0)])), wrec(0x0213, cat([h16(50), h16(100)]))]
    let p = try parse(wmf(recs, nil))
    let pxMM = 96.0 / 25.4
    let (segs, _, _, _) = try pathSegs(item(p, 0))
    let (x, y) = (100.0 * 0.1 * pxMM, 50.0 * 0.1 * pxMM)
    #expect(try closeSeg(seg(segs, 0), .move(0, Float(y))) && closeSeg(seg(segs, 1), .line(Float(x), 0)), "\(segs)")
}

@Test func isotropicModeUsesOneScaleAndKeepsAxisSigns() throws {
    // Window 100 x 50; viewport 400 x -100: the scale is min(4, 2) = 2 on both axes, y flipped.
    let recs = [
        wrec(0x0103, h16(7)),
        wrec(0x020C, cat([h16(50), h16(100)])),
        wrec(0x020E, cat([h16(-100), h16(400)])),
        wrec(0x0214, cat([h16(0), h16(0)])),
        wrec(0x0213, cat([h16(25), h16(50)])),
    ]
    let p = try parse(wmf(recs, nil))
    let (segs, _, _, _) = try pathSegs(item(p, 0))
    #expect(try closeSeg(seg(segs, 0), .move(0, 100)) && closeSeg(seg(segs, 1), .line(100, 50)), "\(segs)")
}

@Test func modifyWorldWithAnUnknownModeKeepsTheTransform() throws {
    let recs = [
        erec(35, xformBytes([2, 0, 0, 2, 0, 0])),
        erec(36, cat([xformBytes([1, 0, 0, 1, 0, 0]), h32(99)])),
        erec(27, cat([e32(0), e32(0)])),
        erec(54, cat([e32(10), e32(5)])),
    ]
    let p = try parse(emf(recs, [0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(try pathSegs(item(p, 0)).0 == [.move(0, 0), .line(20, 10)])
}

@Test func roundRectAcceptsReversedCorners() {
    let normal = roundRect(0, 0, 10, 20, 4, 4)
    #expect(roundRect(10, 20, 0, 0, 4, 4) == normal)
    #expect(roundRect(10, 0, 0, 20, 4, 4) == normal)
}

@Test func strokeWidthIsClampedToThePictureDiagonal() throws {
    // A 1440-unit placeable picture is 72 points square (diagonal 101.8); a 5000-unit pen would be 250.
    let recs = [
        wrec(0x02FA, cat([h16(0), h16(5000), h16(0), h32(0)])),
        wrec(0x012D, h16(0)),
        wrec(0x041B, cat([h16(1440), h16(1440), h16(0), h16(0)])),
    ]
    let p = try parse(wmf(recs, [0, 0, 1440, 1440]))
    #expect((p.width, p.height) == (72, 72))
    let (_, _, stroke, _) = try pathSegs(item(p, 0))
    #expect(close(stroke?.width ?? 0, 72 * Float(2).squareRoot()), "\(String(describing: stroke))")
}

@Test func wmfDibbitbltWithoutADibIsAPatternFill() throws {
    // The 12-word form: rop(4), ySrc, xSrc, reserved, height, width, yDest, xDest; PATCOPY fills with the brush.
    let params = cat([h32(0x00F0_0021), h16(0), h16(0), h16(0), h16(10), h16(20), h16(5), h16(7)])
    let p = try parse(wmf([originRect(), wrec(0x0940, params)], nil))
    let (segs, fill, _, _) = try pathSegs(item(p, 1))
    #expect(fill == C(255, 255, 255, 255))
    #expect(segs == [.move(7, 5), .line(27, 5), .line(27, 15), .line(7, 15), .close])
}

@Test func wmfDibstretchbltWithoutADibIsARopFill() throws {
    // The 14-word form: rop(4), srcH, srcW, ySrc, xSrc, reserved, destH, destW, yDest, xDest; BLACKNESS fills black.
    let params = cat([h32(0x0000_0042), h16(2), h16(2), h16(0), h16(0), h16(0), h16(10), h16(20), h16(5), h16(7)])
    let p = try parse(wmf([originRect(), wrec(0x0B41, params)], nil))
    let (segs, fill, stroke, _) = try pathSegs(item(p, 1))
    #expect(fill == C(0, 0, 0, 255) && stroke == nil)
    #expect(segs == [.move(7, 5), .line(27, 5), .line(27, 15), .line(7, 15), .close])
}

@Test func wmfDibstretchbltStretchesTheDibIntoItsDestination() throws {
    // rop(4), srcH, srcW, ySrc, xSrc, destH, destW, yDest, xDest, then the DIB (no reserved word).
    var params = cat([h32(0x00CC_0020), h16(2), h16(2), h16(0), h16(0), h16(10), h16(20), h16(6), h16(5)])
    params += dib24BottomUp()
    let p = try parse(wmf([originRect(), wrec(0x0B41, params)], nil))
    let b = try bitmap(item(p, 1))
    #expect(b.rect == SIMD4(5, 6, 20, 10))
    #expect(b.rgba == dib24RGBA)
}

@Test func wmfNegativeDestinationHeightMirrorsTheRows() throws {
    let params = cat([h32(0x00CC_0020), h16(0), h16(2), h16(2), h16(0), h16(0), h16(-10), h16(20), h16(0), h16(0), dib24BottomUp()])
    let p = try parse(wmf([wrec(0x0F43, params)], nil))
    let b = try bitmap(item(p, 0))
    #expect(b.rect == SIMD4(0, 0, 20, 10))
    // Blue, green on top; red, white below.
    #expect(b.rgba == [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255])
}

@Test func wmfDibbitbltCopiesTheDibAtItsDestination() throws {
    // The rectangle fixes the picture origin at (0, 0); the DIB lands at x = 5, y = 6.
    var params = cat([h32(0x00CC_0020), h16(0), h16(0), h16(2), h16(2), h16(6), h16(5)])
    params += dib24BottomUp()
    let recs = [wrec(0x041B, cat([h16(10), h16(10), h16(0), h16(0)])), wrec(0x0940, params)]
    let p = try parse(wmf(recs, nil))
    let b = try bitmap(item(p, 1))
    #expect(b.rect == SIMD4(5, 6, 2, 2))
    #expect((b.width, b.height) == (2, 2))
    #expect(b.rgba == dib24RGBA)
}

@Test func emfSetdibitstodeviceDrawsTheImageAtItsOwnSize() throws {
    let dib = dib24BottomUp()
    let (info, bits) = (Array(dib[..<40]), Array(dib[40...]))
    // Destination x/y at 24, src x/y at 32, size at 40, bmi at 48 (offset, length), bits at 56, scan start 68
    // and scan count 72.
    let fields: [(Int, UInt32)] = [(24, 10), (28, 20), (40, 2), (44, 2), (48, 112), (52, 40), (56, 152), (60, 16), (72, 2)]
    let rec = erecAt(80, 168, fields, [(112, info), (152, bits)])
    let p = try parse(emf([rec], [0, 0, 0, 0], [0, 0, 0, 0]))
    let b = try bitmap(item(p, 0))
    #expect(b.rect == SIMD4(0, 0, 2, 2))
    #expect(b.rgba == dib24RGBA)
}

@Test func emfSetdibitstodeviceSourceCountsFromTheStartScan() throws {
    // ySrc 1 with the bits starting at scan 1 is source row 0 of the bits: the bottom row (blue, green), drawn
    // cxSrc x cySrc = 2 x 1 at the destination.
    let dib = dib24BottomUp()
    let (info, bits) = (Array(dib[..<40]), Array(dib[40...]))
    let fields: [(Int, UInt32)] = [(24, 10), (28, 20), (36, 1), (40, 2), (44, 1), (48, 112), (52, 40), (56, 152), (60, 16), (68, 1), (72, 2)]
    let rec = erecAt(80, 168, fields, [(112, info), (152, bits)])
    let r = erec(43, cat([e32(0), e32(0), e32(1), e32(1)]))
    let p = try parse(emf([r, rec], [0, 0, 0, 0], [0, 0, 0, 0]))
    let b = try bitmap(item(p, 1))
    #expect(b.rect == SIMD4(10, 20, 2, 1))
    #expect(b.rgba == [0, 0, 255, 255, 0, 255, 0, 255])
}
