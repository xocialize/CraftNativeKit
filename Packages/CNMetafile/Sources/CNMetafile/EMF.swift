// CNMetafile — EMF reader (MS-EMF). Records are (type, size in bytes) followed by a payload; offsets inside a record
// (bitmap info and bits) are relative to the record start, so each handler reads the record slice. Port of deckcraft
// crates/metafile/src/emf.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). Blits decode only
// the cropped part of a DIB, as WordCraft crates/metafile/src/emf.rs at fd7f6621 (MIT OR Apache-2.0, © ArtCraft Team
// and the WordCraft contributors) does (45d2546b).
import CNCore

enum EMF {
    /// ExtTextOut options: no rectangle in the record (EMR_SMALLTEXTOUT, EmrText), and 8-bit characters
    /// (EMR_SMALLTEXTOUT).
    private static let etoNoRect: UInt32 = 0x0100
    private static let etoSmallChars: UInt32 = 0x0200

    private static let signature: UInt32 = 0x464D_4520
    /// Hundredths of a millimetre to points.
    private static let hmmToPt = 72.0 / 2540.0
    /// SRCCOPY, the plain copy of a bitmap.
    private static let srcCopy: UInt32 = 0x00CC_0020
    /// LogPenEx pen type bits; PS_COSMETIC pens are one device pixel wide.
    private static let psTypeMask: UInt32 = 0x000F_0000
    private static let psCosmetic: UInt32 = 0

    static func isEMF(_ b: Bytes) -> Bool {
        b.u32(0) == 1 && b.u32(40) == signature
    }

    /// The picture frame: `rclFrame` (0.01 mm) mapped to device units through `szlDevice` and `szlMillimeters`,
    /// sized in points. Without a usable frame, the device bounds stand in (1 unit = 1 point).
    static func parse(_ input: Bytes, depth: Int = 0) throws(MetafileError) -> (Canvas, Frame?) {
        guard isEMF(input) else { throw .badHeader }
        guard let hsize32 = input.u32(4), let bounds = rect32(input, 8) else { throw .badHeader }
        let hsize = Int(hsize32)
        let (l, t, r, b) = (bounds[0], bounds[1], bounds[2], bounds[3])
        let frame = frameFromHeader(input) ?? (r > l && b > t ? Frame(rect: R4(l, t, r - l, b - t), size: nil) : nil)
        var cv = Canvas()
        if r > l && b > t { cv.setClipSurface(R4(l, t, r, b)) }
        if let pxMM = devicePxPerMM(input) { cv.setDeviceMM(pxMM) }
        var plus = Plus(depth: depth)
        plus.frame = frame?.rect
        var parsed = 0
        var pos = Swift.max(hsize, 88)
        while !cv.full {
            guard let typ = input.u32(pos), let size32 = input.u32(pos.addingSaturating(4)) else { break }
            let size = Int(size32)
            if size < 8 || size % 4 != 0 { break }
            guard let rec = input.slice(pos, size) else { break }
            if typ == 14 { break }
            if typ == 70 && rec.u32(12) == Plus.emfPlus {
                if let data = rec.tail(16) { plus.comment(&cv, data) }
            } else {
                record(&cv, typ, rec)
            }
            parsed += 1
            let (next, overflow) = pos.addingReportingOverflow(size)
            if overflow { break }
            pos = next
        }
        if parsed == 0 { throw .noRecords }
        return (cv, frame)
    }

    /// Device pixels per millimetre on each axis, from `szlDevice` (72) and `szlMillimeters` (80).
    private static func devicePxPerMM(_ input: Bytes) -> P? {
        guard let dw = input.i32(72), let dh = input.i32(76), let mw = input.i32(80), let mh = input.i32(84) else { return nil }
        guard dw > 0, dh > 0, mw > 0, mh > 0 else { return nil }
        return P(Double(dw) / Double(mw), Double(dh) / Double(mh))
    }

    /// The frame from `rclFrame` (offset 24), `szlDevice` (72) and `szlMillimeters` (80) in the header.
    static func frameFromHeader(_ input: Bytes) -> Frame? {
        guard let f = rect32(input, 24) else { return nil }
        let (fl, ft, fr, fb) = (f[0], f[1], f[2], f[3])
        if fr <= fl || fb <= ft { return nil }
        // Device units per hundredth of a millimetre.
        guard let pxMM = devicePxPerMM(input) else { return nil }
        let (sx, sy) = (pxMM.x / 100, pxMM.y / 100)
        let rect = R4(fl * sx, ft * sy, (fr - fl) * sx, (fb - ft) * sy)
        return Frame(rect: rect, size: ((fr - fl) * hmmToPt, (fb - ft) * hmmToPt))
    }

    private static func record(_ cv: inout Canvas, _ typ: UInt32, _ r: Bytes) {
        if cv.full { return }
        switch typ {
        case 9: if let p = xy32(r, 8) { cv.setWindowExt(p) }
        case 10: if let p = xy32(r, 8) { cv.setWindowOrg(p) }
        case 11: if let p = xy32(r, 8) { cv.setViewportExt(p) }
        case 12: if let p = xy32(r, 8) { cv.setViewportOrg(p) }
        case 17: if let m = r.u32(8) { cv.setMapMode(m) }
        case 19: if let m = r.u32(8) { cv.setPolyfill(m) }
        case 20: if let m = r.u32(8) { cv.setRop2(m) }
        case 33: cv.saveDC()
        case 34: if let n = r.i32(8) { cv.restoreDC(n) }
        case 35: if let x = xform(r, 8) { cv.modifyWorld(x, 4) }
        case 36: if let x = xform(r, 8), let m = r.u32(32) { cv.modifyWorld(x, m) }
        case 37: if let i = r.u32(8) { cv.select(i) }
        case 38: createPen(&cv, r)
        case 95: createExtPen(&cv, r)
        case 39: createBrush(&cv, r)
        case 93, 94: createDIBBrush(&cv, r, mono: typ == 93)
        case 82: createFont(&cv, r)
        case 18: if let m = r.u32(8) { cv.setBkMode(m) }
        case 22: if let a = r.u32(8) { cv.setTextAlign(a) }
        case 24: if let c = r.u32(8) { cv.setTextColor(c) }
        case 25: if let c = r.u32(8) { cv.setBkColor(c) }
        case 83, 84: extTextOut(&cv, r, wide: typ == 84)
        case 108: smallTextOut(&cv, r)
        case 40: if let i = r.u32(8) { cv.deleteObject(i) }
        case 29: if let rect = rect32(r, 8) { cv.excludeClipRect(rect) }
        case 30: if let rect = rect32(r, 8) { cv.intersectClipRect(rect) }
        case 75: extSelectClip(&cv, r)
        case 27: if let p = xy32(r, 8) { cv.moveTo(p) }
        case 54: if let p = xy32(r, 8) { cv.lineTo(p) }
        case 42: if let b = rect32(r, 8) { cv.shape(ellipse(b[0], b[1], b[2], b[3]), fill: true, stroke: true) }
        case 43: if let b = rect32(r, 8) { cv.shape(rect(b[0], b[1], b[2], b[3]), fill: true, stroke: true) }
        case 44:
            guard let cw = r.i32(24), let ch = r.i32(28), let b = rect32(r, 8) else { return }
            cv.shape(roundRect(b[0], b[1], b[2], b[3], Double(cw), Double(ch)), fill: true, stroke: true)
        case 45 ... 47:
            guard let (b, s, e) = arc32(r) else { return }
            let kind: ArcKind = switch typ {
            case 45: .arc
            case 46: .chord
            default: .pie
            }
            cv.shape(arcShape(b[0], b[1], b[2], b[3], s, e, kind), fill: kind != .arc, stroke: true)
        case 4, 87: if let pts = counted(r, wide: typ == 4) { cv.poly(pts, close: false, fill: false, stroke: true) }
        case 3, 86: if let pts = counted(r, wide: typ == 3) { cv.poly(pts, close: true, fill: true, stroke: true) }
        case 6, 89: if let pts = counted(r, wide: typ == 6) { cv.lineChain(pts, fill: false, stroke: true) }
        // POLYBEZIER starts its own figure at the first point and leaves the current point alone; POLYBEZIERTO
        // continues from the current point.
        case 2, 85:
            if let pts = counted(r, wide: typ == 2), let from = pts.first { cv.bezier(from, Array(pts.dropFirst())) }
        case 5, 88: if let pts = counted(r, wide: typ == 5) { cv.bezierTo(pts) }
        case 7, 90:
            if let (counts, pts) = polyGroups(r, wide: typ == 7) { cv.shape(subpaths(pts, counts, close: false), fill: false, stroke: true) }
        case 8, 91:
            if let (counts, pts) = polyGroups(r, wide: typ == 8) { cv.shape(subpaths(pts, counts, close: true), fill: true, stroke: true) }
        case 59: cv.beginPath()
        case 60: cv.endPath()
        case 61: cv.closeFigure()
        case 62: cv.paintPath(fill: true, stroke: false)
        case 63: cv.paintPath(fill: true, stroke: true)
        case 64: cv.paintPath(fill: false, stroke: true)
        case 76, 77: bitblt(&cv, r, stretch: typ == 77)
        case 80: setDIBits(&cv, r)
        case 81: stretchDIBits(&cv, r)
        case 114: alphaBlend(&cv, r)
        default: break
        }
    }

    /// EMR_EXTSELECTCLIPRGN: `cbRgnData` bytes of `RGNDATA` (rectangles in logical units) and a region mode. No
    /// region data selects the default clip.
    private static func extSelectClip(_ cv: inout Canvas, _ r: Bytes) {
        guard let cb32 = r.u32(8), let mode = r.u32(12) else { return }
        let cb = Int(cb32)
        if cb == 0 { return cv.resetClip() }
        let header = 16
        if cb < 32 { return }
        // RDH_RECTANGLES is the only region type GDI writes.
        guard let kind = r.u32(header + 4), kind == 1, let count = r.u32(header + 8) else { return }
        let n = Swift.min(Int(count), Clip.maxClipRects)
        let end = header + cb
        var rects: [R4] = []
        for i in 0 ..< n {
            let o = header + 32 + i * 16
            if o + 16 > end { break }
            guard let rect = rect32(r, o) else { return }
            rects.append(rect)
        }
        cv.selectClipRects(rects, mode)
    }

    /// Two little-endian i32 values at `off`, as a point.
    static func xy32(_ r: Bytes, _ off: Int) -> P? {
        guard let x = r.i32(off), let y = r.i32(off + 4) else { return nil }
        return P(Double(x), Double(y))
    }

    /// RECTL (left, top, right, bottom) as i32 values widened to f64.
    static func rect32(_ r: Bytes, _ off: Int) -> R4? {
        guard let l = r.i32(off), let t = r.i32(off + 4), let rr = r.i32(off + 8), let b = r.i32(off + 12) else { return nil }
        return R4(Double(l), Double(t), Double(rr), Double(b))
    }

    /// An i32 field as f64; 0 past the end.
    private static func i32s(_ r: Bytes, _ off: Int) -> Double {
        r.i32(off).map(Double.init) ?? 0
    }

    /// XFORM: six f32 values in M11, M12, M21, M22, Dx, Dy order.
    private static func xform(_ r: Bytes, _ off: Int) -> Xform? {
        var x: Xform = []
        for i in 0 ..< 6 {
            guard let v = r.f32(off + i * 4) else { return nil }
            x.append(Double(v))
        }
        return x
    }

    /// ARC, CHORD, PIE: bounds at 8, start point at 24, end point at 32.
    private static func arc32(_ r: Bytes) -> (R4, P, P)? {
        guard let b = rect32(r, 8), let s = xy32(r, 24), let e = xy32(r, 32) else { return nil }
        return (b, s, e)
    }

    /// A point count from a record, rejected when it exceeds the path budget (before any allocation).
    private static func budget(_ n: UInt32) -> Int? {
        Int(n) <= Metafile.maxPathOps ? Int(n) : nil
    }

    /// Point count at 24, then the points (32-bit or 16-bit) at 28.
    private static func counted(_ r: Bytes, wide: Bool) -> [P]? {
        guard let c = r.u32(24), let n = budget(c) else { return nil }
        return r.tail(28)?.points(0, n, wide: wide)
    }

    /// Subpath count at 24, total point count at 28, per-subpath counts at 32, then the points.
    private static func polyGroups(_ r: Bytes, wide: Bool) -> ([Int], [P])? {
        guard let c = r.u32(24), let n = budget(c) else { return nil }
        // The record must hold the n counts before anything is allocated for them.
        guard let raw = r.slice(32, n * 4) else { return nil }
        var counts: [Int] = []
        counts.reserveCapacity(n)
        var total = 0
        for i in 0 ..< n {
            guard let v = raw.u32(i * 4) else { return nil }
            counts.append(Int(v))
            total += Int(v)
        }
        guard let t32 = UInt32(exactly: total), let t = budget(t32) else { return nil }
        guard let pts = r.tail(n * 4 + 32)?.points(0, t, wide: wide) else { return nil }
        return (counts, pts)
    }

    /// EMR_CREATEPEN: handle, LogPen (style, width x/y, colour).
    private static func createPen(_ cv: inout Canvas, _ r: Bytes) {
        guard let slot = r.u32(8), let style = r.u32(12), let width = r.i32(16), let color = r.u32(24) else { return }
        cv.addObject(Int(slot), .pen(Pen(style: style, width: Double(width), color: colorref(color))))
    }

    /// EMR_EXTCREATEPEN: handle, bitmap offsets (unused), LogPenEx (style, width, brush style, colour). A cosmetic
    /// pen's width is in device pixels (always 1), so it is a hairline; a BS_NULL brush draws no line at all.
    private static func createExtPen(_ cv: inout Canvas, _ r: Bytes) {
        guard let slot = r.u32(8), let style = r.u32(28), let width = r.u32(32), let brush = r.u32(36), let color = r.u32(40) else {
            return
        }
        let w = style & psTypeMask == psCosmetic ? 0 : Double(width)
        let s = brush == bsNull ? psNull : style & psStyleMask
        cv.addObject(Int(slot), .pen(Pen(style: s, width: w, color: colorref(color))))
    }

    /// EMR_CREATEBRUSHINDIRECT: handle, LogBrush32 (style, colour, hatch).
    private static func createBrush(_ cv: inout Canvas, _ r: Bytes) {
        guard let slot = r.u32(8), let style = r.u32(12), let color = r.u32(16) else { return }
        var b = Brush(style, colorref(color))
        if style == bsHatched { b.hatch = r.u32(20) ?? 0 }
        cv.addObject(Int(slot), .brush(b))
    }

    /// EMR_CREATEDIBPATTERNBRUSHPT (94) and EMR_CREATEMONOBRUSH (93): handle, colour usage, then the bitmap info
    /// and bits as offset/size pairs. A mono brush (or one whose palette holds indices, DIB_PAL_COLORS) takes the
    /// text and background colours. An undecodable bitmap leaves the slot empty.
    private static func createDIBBrush(_ cv: inout Canvas, _ r: Bytes, mono: Bool) {
        guard let slot = r.u32(8), let usage = r.u32(12), let bo = r.u32(16), let bl = r.u32(20), let po = r.u32(24),
              let pl = r.u32(28), let info = r.slice(Int(bo), Int(bl)), let bits = r.slice(Int(po), Int(pl)),
              let img = DIB.decode(info, bits, keepAlpha: false), let b = Brush.pattern(img, mono: mono || usage == 1)
        else { return }
        cv.addObject(Int(slot), .brush(b))
    }

    /// EMR_EXTCREATEFONTINDIRECTW: handle, then a LogFont (MS-EMF 2.2.13): height, width, escapement,
    /// orientation, weight (i32 each), italic, underline, strike-out, charset and four more bytes, then the face
    /// name in 32 UTF-16 units (NUL-terminated).
    private static func createFont(_ cv: inout Canvas, _ r: Bytes) {
        guard let slot = r.u32(8), let height = r.i32(12) else { return }
        let width = r.i32(16) ?? 0
        let escapement = r.i32(20) ?? 0
        let weight = r.i32(28) ?? 0
        func byte(_ o: Int) -> UInt8 { r.byte(o) ?? 0 }
        var units: [UInt16] = []
        for i in 0 ..< 32 {
            guard let u = r.u16(40 + 2 * i), u != 0 else { break }
            units.append(u)
        }
        let (family, _) = decodeUTF16(units, [])
        let font = MetafileFont(
            family: String(rustTrim(family)),
            height: Float(height),
            width: Float(width),
            weight: UInt16(Swift.min(Swift.max(weight, 0), 1000)),
            italic: byte(32) != 0,
            underline: byte(33) != 0,
            strike: byte(34) != 0,
            charset: byte(35)
        )
        cv.addObject(Int(slot), .font(LogFont(font: font, escapement: Double(escapement))))
    }

    /// The dx array at `off` for `n` characters: i32 advances, or (dx, dy) pairs under ETO_PDY (only dx is used).
    /// Empty when absent or short.
    private static func dxArray(_ r: Bytes, _ off: Int, _ n: Int, _ opts: UInt32) -> [Float] {
        let step = opts & etoPDY != 0 ? 8 : 4
        if off == 0 { return [] }
        var dx: [Float] = []
        for i in 0 ..< n {
            guard let v = r.i32(off + i * step) else { break }
            dx.append(Float(v))
        }
        return dx.count == n ? dx : []
    }

    private static func utf16Units(_ raw: Bytes) -> [UInt16] {
        (0 ..< raw.count / 2).map { raw.u16($0 * 2) ?? 0 }
    }

    /// EMR_EXTTEXTOUTA (83) and EMR_EXTTEXTOUTW (84): bounds, graphics mode and scales, then an EmrText at 36:
    /// reference point, character count, string offset, options, the rectangle (absent under ETO_NO_RECT) and the
    /// dx offset. Offsets count from the record start. Glyph-index strings name glyphs of a font the reader cannot
    /// match, so they are left out.
    private static func extTextOut(_ cv: inout Canvas, _ r: Bytes, wide: Bool) {
        guard let at = xy32(r, 36), let count = r.u32(44), let off32 = r.u32(48), let opts = r.u32(52) else { return }
        let n = Swift.min(Int(count), maxChars)
        let off = Int(off32)
        let rect: R4?
        let dxOff: UInt32
        if opts & etoNoRect != 0 {
            guard let d = r.u32(56) else { return }
            (rect, dxOff) = (nil, d)
        } else {
            guard let d = r.u32(72) else { return }
            (rect, dxOff) = (rect32(r, 56), d)
        }
        if opts & etoGlyphIndex != 0 { return }
        let dx = dxArray(r, Int(dxOff), n, opts)
        let decoded: (String, [Float])
        if wide {
            guard let raw = r.slice(off, n * 2) else { return }
            decoded = decodeUTF16(utf16Units(raw), dx)
        } else {
            guard let raw = r.slice(off, n) else { return }
            decoded = decodeBytes(raw.array, cv.fontCharset, dx)
        }
        cv.text(at, decoded.0, decoded.1, opts, rect)
    }

    /// EMR_SMALLTEXTOUT (MS-EMF 2.3.5.37): x, y, character count, options, graphics mode, scales, the bounds
    /// (absent under ETO_NO_RECT), then the characters: 8-bit under ETO_SMALL_CHARS, else UTF-16.
    private static func smallTextOut(_ cv: inout Canvas, _ r: Bytes) {
        guard let at = xy32(r, 8), let count = r.u32(16), let opts = r.u32(20) else { return }
        let n = Swift.min(Int(count), maxChars)
        if opts & etoGlyphIndex != 0 { return }
        let (rect, off): (R4?, Int) = opts & etoNoRect != 0 ? (nil, 36) : (rect32(r, 36), 52)
        let text: String
        if opts & etoSmallChars != 0 {
            guard let raw = r.slice(off, n) else { return }
            text = decodeBytes(raw.array, cv.fontCharset, []).0
        } else {
            guard let raw = r.slice(off, n * 2) else { return }
            text = decodeUTF16(utf16Units(raw), []).0
        }
        cv.text(at, text, [], opts, rect)
    }

    /// BITBLT (76) and STRETCHBLT (77): dest at 24..40, rop at 40, source x/y at 44, bmi at 84, bits at 92;
    /// STRETCHBLT adds the source w/h at 100. A source-less rop fills the destination instead.
    private static func bitblt(_ cv: inout Canvas, _ r: Bytes, stretch: Bool) {
        let dst = R4(i32s(r, 24), i32s(r, 28), i32s(r, 32), i32s(r, 36))
        guard let rop = r.u32(40) else { return }
        if Canvas.sourceless(rop) { return cv.fillRop(dst, rop) }
        let (sw, sh) = stretch ? (i32s(r, 100), i32s(r, 104)) : (dst[2], dst[3])
        let src = R4(i32s(r, 44), i32s(r, 48), sw, sh)
        blit(&cv, r, dst, src, (84, 92), .rop(rop))
    }

    /// ALPHABLEND: laid out like STRETCHBLT, with a BLENDFUNCTION at 40. Constant alpha at 42 applies to every
    /// pixel; AlphaFormat at 43 with AC_SRC_ALPHA (1) also uses the per-pixel alpha.
    private static func alphaBlend(_ cv: inout Canvas, _ r: Bytes) {
        let dst = R4(i32s(r, 24), i32s(r, 28), i32s(r, 32), i32s(r, 36))
        guard let constant = r.byte(42), let format = r.byte(43) else { return }
        let src = R4(i32s(r, 44), i32s(r, 48), i32s(r, 100), i32s(r, 104))
        blit(&cv, r, dst, src, (84, 92), .alpha(constant: constant, perPixel: format & 0x01 != 0))
    }

    /// STRETCHDIBITS: dest x/y at 24, src x/y/w/h at 32..48, bmi offset/size at 48, bits at 56, rop at 68, dest
    /// w/h at 72.
    private static func stretchDIBits(_ cv: inout Canvas, _ r: Bytes) {
        let dst = R4(i32s(r, 24), i32s(r, 28), i32s(r, 72), i32s(r, 76))
        let src = R4(i32s(r, 32), i32s(r, 36), i32s(r, 40), i32s(r, 44))
        guard let rop = r.u32(68) else { return }
        blit(&cv, r, dst, src, (48, 56), .rop(rop))
    }

    /// SETDIBITSTODEVICE (MS-EMF 2.3.1.5): dest x/y at 24, src x/y at 32, size (cxSrc, cySrc) at 40, bmi at 48,
    /// bits at 56, start scan at 68. The image keeps its own size; the bits begin at scan line `iStartScan`, so
    /// the source y counts from there.
    private static func setDIBits(_ cv: inout Canvas, _ r: Bytes) {
        let (cx, cy) = (i32s(r, 40), i32s(r, 44))
        if cx <= 0 || cy <= 0 { return }
        let dst = R4(i32s(r, 24), i32s(r, 28), cx, cy)
        guard let start = r.u32(68) else { return }
        let src = R4(i32s(r, 32), i32s(r, 36) - Double(start), cx, cy)
        blit(&cv, r, dst, src, (48, 56), .rop(srcCopy))
    }

    /// Decodes the bitmap at `at` = (offset of the bmi offset/length pair, offset of the bits pair), both inside
    /// the record, and stretches the source rectangle `src` into `dst`. Both are `[x, y, w, h]`; a non-positive
    /// source size means the whole bitmap. `blend` decides how it combines.
    private static func blit(_ cv: inout Canvas, _ r: Bytes, _ dst: R4, _ src: R4, _ at: (Int, Int), _ blend: Blend) {
        guard let bo = r.u32(at.0), let bl = r.u32(at.0 + 4), let po = r.u32(at.1), let pl = r.u32(at.1 + 4), pl != 0,
              let info = r.slice(Int(bo), Int(bl)), let pixels = r.slice(Int(po), Int(pl)),
              case let s = [Int64(rustCast: src[0]), Int64(rustCast: src[1]), Int64(rustCast: src[2]), Int64(rustCast: src[3])],
              case (var img, let d)? = DIB.decodeClip(info, pixels, keepAlpha: blend.perPixel, s, dst)
        else { return }
        DIB.prepare(&img, blend)
        cv.bitmap(d, img)
    }
}
