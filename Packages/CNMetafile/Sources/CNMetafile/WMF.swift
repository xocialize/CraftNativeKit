// CNMetafile — WMF reader (MS-WMF). A file is an optional 22-byte placeable header, a 9-word standard header,
// then records of (size in 16-bit words, function, parameters). Parameters are read at byte 6 of each record.
// Port of deckcraft crates/metafile/src/wmf.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import CNCore

enum WMF {
    private static let placeableKey: UInt32 = 0x9AC6_CDD7
    private static let defaultInch = 1440.0
    /// A placeable WMF plays into a target sized in points; brushes are laid out in 96-dpi pixels.
    private static let ptPerPx = 72.0 / 96.0

    static func isWMF(_ b: Bytes) -> Bool {
        if b.u32(0) == placeableKey { return true }
        guard let k = b.u16(0), let h = b.u16(2), let v = b.u16(4) else { return false }
        return (k == 1 || k == 2) && h == 9 && (v == 0x100 || v == 0x300)
    }

    /// Reads all records. Returns the drawing state and the picture frame, or an error when no record could be
    /// read at all.
    static func parse(_ input: Bytes) throws(MetafileError) -> (Canvas, Frame?) {
        let placeable = input.u32(0) == placeableKey
        // Placeable bounds: logical corners (left, top, right, bottom) and their size in points.
        var hdr = 0
        var bounds: (R4, P)?
        if placeable {
            guard let l = input.i16(6), let t = input.i16(8), let r = input.i16(10), let b = input.i16(12) else { throw .badHeader }
            let (l64, t64, r64, b64) = (Double(l), Double(t), Double(r), Double(b))
            let inch = input.u16(14).flatMap { $0 > 0 ? Double($0) : nil } ?? defaultInch
            let (w, h) = (r64 - l64, b64 - t64)
            if w > 0 && h > 0 { bounds = (R4(l64, t64, r64, b64), P(w * 72 / inch, h * 72 / inch)) }
            hdr = 22
        }
        guard let hsize16 = input.u16(hdr + 2) else { throw .badHeader }
        let hsize = Int(hsize16)
        if hsize < 9 { throw .badHeader }
        var pos = hdr + hsize * 2
        // Played into a target like Word does: the placeable bounds are the first window, the target (the picture
        // size) the viewport. A plain WMF's target is its first window.
        var cv = Canvas()
        if let (c, size) = bounds {
            cv.playInto(R4(c[0], c[1], c[2] - c[0], c[3] - c[1]), size)
            cv.setClipSurface(R4(0, 0, size.x, size.y))
            cv.patternPx = ptPerPx
        }
        var playerViewport = bounds != nil
        var parsed = 0
        while !cv.full {
            guard let words = input.u32(pos), let fn = input.u16(pos.addingSaturating(4)) else { break }
            let (len, overflow) = Int(words).multipliedReportingOverflow(by: 2)
            if overflow || len < 6 { break }
            guard let rec = input.slice(pos, len) else { break }
            if fn == 0 { break }
            record(&cv, fn, rec)
            if fn == 0x020C && cv.windowSet && !playerViewport && !cv.viewportSet {
                let we = cv.map.windowExt
                cv.playInto(nil, P(Swift.abs(we.x), Swift.abs(we.y)))
                playerViewport = true
            }
            parsed += 1
            let (next, o2) = pos.addingReportingOverflow(len)
            if o2 { break }
            pos = next
        }
        if parsed == 0 { throw .noRecords }
        let frame: Frame?
        if let (c, size) = bounds {
            if !cv.viewportSet && cv.map.usesExtents {
                // Played into its target: the frame is the target.
                frame = Frame(rect: R4(0, 0, size.x, size.y), size: (size.x, size.y))
            } else {
                // The file set its own viewport, so the drawing is in its device units and the logical bounds go
                // through the final mapping.
                let (a, b) = (cv.map.device(P(c[0], c[1])), cv.map.device(P(c[2], c[3])))
                let rect = R4(a.x.rustMin(b.x), a.y.rustMin(b.y), Swift.abs(b.x - a.x), Swift.abs(b.y - a.y))
                frame = rect[2] > 0 && rect[3] > 0 ? Frame(rect: rect, size: (size.x, size.y)) : nil
            }
        } else if playerViewport && !cv.viewportSet && cv.map.usesExtents {
            let ve = cv.map.viewportExt
            frame = Frame(rect: R4(0, 0, ve.x, ve.y), size: nil)
        } else if cv.windowSet {
            frame = Frame(rect: cv.map.windowRect, size: nil)
        } else {
            frame = nil
        }
        return (cv, frame)
    }

    private static func record(_ cv: inout Canvas, _ fn: UInt16, _ r: Bytes) {
        if cv.full { return }
        switch fn {
        case 0x0103: if let m = r.u16(6) { cv.setMapMode(UInt32(m)) }
        case 0x0106: if let m = r.u16(6) { cv.setPolyfill(UInt32(m)) }
        case 0x0104: if let m = r.u16(6) { cv.setRop2(UInt32(m)) }
        // Y is stored before X in these records.
        case 0x020B: if let p = xy16(r, 6) { cv.setWindowOrg(p) }
        case 0x020C: if let p = xy16(r, 6) { cv.setWindowExt(p) }
        case 0x020D: if let p = xy16(r, 6) { cv.setViewportOrg(p) }
        case 0x020E: if let p = xy16(r, 6) { cv.setViewportExt(p) }
        case 0x001E: cv.saveDC()
        case 0x0127: if let n = r.i16(6) { cv.restoreDC(Int32(n)) }
        case 0x0214: if let p = xy16(r, 6) { cv.moveTo(p) }
        case 0x0213: if let p = xy16(r, 6) { cv.lineTo(p) }
        case 0x0325: if let pts = countedPoints(r) { cv.poly(pts, close: false, fill: false, stroke: true) }
        case 0x0324: if let pts = countedPoints(r) { cv.poly(pts, close: true, fill: true, stroke: true) }
        case 0x0538: if let ops = polypolygon(r) { cv.shape(ops, fill: true, stroke: true) }
        case 0x041B: if let b = rect16(r, 6) { cv.shape(rect(b[0], b[1], b[2], b[3]), fill: true, stroke: true) }
        case 0x061C:
            guard let ew = r.i16(8), let eh = r.i16(6), let b = rect16(r, 10) else { return }
            cv.shape(roundRect(b[0], b[1], b[2], b[3], Double(ew), Double(eh)), fill: true, stroke: true)
        case 0x0415: if let b = rect16(r, 6) { cv.excludeClipRect(b) }
        case 0x0416: if let b = rect16(r, 6) { cv.intersectClipRect(b) }
        case 0x0418: if let b = rect16(r, 6) { cv.shape(ellipse(b[0], b[1], b[2], b[3]), fill: true, stroke: true) }
        case 0x0817, 0x081A, 0x0830:
            guard let (b, s, e) = arc16(r) else { return }
            let kind: ArcKind = switch fn {
            case 0x0817: .arc
            case 0x081A: .pie
            default: .chord
            }
            cv.shape(arcShape(b[0], b[1], b[2], b[3], s, e, kind), fill: kind != .arc, stroke: true)
        case 0x02FA: createPen(&cv, r)
        case 0x02FC: createBrush(&cv, r)
        case 0x02FB: cv.addObject(nil, .font(font(r) ?? LogFont()))
        case 0x0142:
            // A pattern the reader cannot decode still takes its handle slot.
            cv.addObject(nil, dibPatternBrush(r).map { .brush($0) } ?? .other)
        // Palettes, old-style pattern brushes and regions take a handle slot too, so later SELECTOBJECT handles
        // count them; selecting one draws nothing.
        case 0x00F7, 0x01F9, 0x06FF: cv.addObject(nil, .other)
        case 0x0209: if let c = r.u32(6) { cv.setTextColor(c) }
        case 0x0201: if let c = r.u32(6) { cv.setBkColor(c) }
        case 0x0102: if let m = r.u16(6) { cv.setBkMode(UInt32(m)) }
        case 0x012E: if let a = r.u16(6) { cv.setTextAlign(UInt32(a)) }
        case 0x0A32: extTextOut(&cv, r)
        case 0x0521: textOut(&cv, r)
        // PATBLT: rop(4), height, width, y, x.
        case 0x061D: if let rop = r.u32(6) { cv.fillRop(R4(i16s(r, 16), i16s(r, 14), i16s(r, 12), i16s(r, 10)), rop) }
        case 0x012D: if let h = r.u16(6) { cv.select(wmfHandle(h)) }
        case 0x01F0: if let h = r.u16(6) { cv.deleteObject(UInt32(h)) }
        // STRETCHDIB: rop(4) usage(2) srcH srcW ySrc xSrc destH destW yDest xDest, then the DIB.
        case 0x0F43:
            let rop = r.u32(6) ?? 0
            dibBlit(&cv, r, 28, rop, R4(i16s(r, 26), i16s(r, 24), i16s(r, 22), i16s(r, 20)), R4(i16s(r, 18), i16s(r, 16), i16s(r, 14), i16s(r, 12)))
        case 0x0B41: dibStretchBlt(&cv, r)
        case 0x0940: dibBitBlt(&cv, r)
        default: break
        }
    }

    /// A 16-bit WMF handle as a canvas object index: stock objects are `0x8000 | index`, which the canvas reads
    /// with the 32-bit stock flag.
    private static func wmfHandle(_ h: UInt16) -> UInt32 {
        let h = UInt32(h)
        return h & 0x8000 != 0 ? (h & 0x7FFF) | 0x8000_0000 : h
    }

    /// An i16 field as f64; 0 past the end.
    private static func i16s(_ r: Bytes, _ off: Int) -> Double {
        r.i16(off).map(Double.init) ?? 0
    }

    /// CREATEPENINDIRECT: style, width (x, y), colour. Only the width's x component is used.
    private static func createPen(_ cv: inout Canvas, _ r: Bytes) {
        guard let style = r.u16(6), let width = r.i16(8), let color = r.u32(12) else { return }
        cv.addObject(nil, .pen(Pen(style: UInt32(style), width: Double(width), color: colorref(color))))
    }

    /// CREATEBRUSHINDIRECT: style, colour, hatch.
    private static func createBrush(_ cv: inout Canvas, _ r: Bytes) {
        guard let s = r.u16(6), let color = r.u32(8) else { return }
        let style = UInt32(s)
        var b = Brush(style, colorref(color))
        if style == bsHatched { b.hatch = UInt32(r.u16(12) ?? 0) }
        cv.addObject(nil, .brush(b))
    }

    /// DIBCREATEPATTERNBRUSH: style, colour usage, then a DIB (MS-WMF 2.3.4.8). The DIB's own palette gives the
    /// colours; with DIB_PAL_COLORS (indices into a palette the reader does not keep) a monochrome DIB takes the
    /// text and background colours.
    private static func dibPatternBrush(_ r: Bytes) -> Brush? {
        guard let usage = r.u16(8), let dib = r.tail(10), let n = DIB.infoLen(dib), let info = dib.slice(0, n),
              let bits = dib.tail(n), let img = DIB.decode(info, bits, keepAlpha: false)
        else { return nil }
        return Brush.pattern(img, mono: usage == 1)
    }

    /// Font object (MS-WMF 2.2.1.2): height, width, escapement, orientation, weight (i16 each), italic, underline,
    /// strike-out and charset bytes, three precision/quality bytes, pitch and family, then the face name (up to 32
    /// bytes, NUL-terminated, in the font's character set).
    private static func font(_ r: Bytes) -> LogFont? {
        guard let height = r.i16(6) else { return nil }
        let width = r.i16(8) ?? 0
        let escapement = r.i16(10) ?? 0
        let weight = r.i16(14) ?? 0
        func byte(_ o: Int) -> UInt8 { r.byte(o) ?? 0 }
        let charset = byte(19)
        let name = (r.tail(24)?.array ?? []).prefix(32).prefix { $0 != 0 }
        // Face names are plain ASCII in practice; other bytes go through the Western code page.
        let (family, _) = decodeBytes(Array(name), 0, [])
        return LogFont(
            font: MetafileFont(
                family: String(rustTrim(family)),
                height: Float(height),
                width: Float(width),
                weight: UInt16(Swift.min(Swift.max(weight, 0), 1000)),
                italic: byte(16) != 0,
                underline: byte(17) != 0,
                strike: byte(18) != 0,
                charset: charset
            ),
            escapement: Double(escapement)
        )
    }

    /// EXTTEXTOUT (MS-WMF 2.3.3.5): y, x, string length, options, the rectangle (left, top, right, bottom) when
    /// ETO_OPAQUE or ETO_CLIPPED is set, the string padded to a word, then an optional dx array of i16 advances.
    private static func extTextOut(_ cv: inout Canvas, _ r: Bytes) {
        guard let y = r.i16(6), let x = r.i16(8), let count = r.u16(10), let o = r.u16(12) else { return }
        var n = Swift.min(Int(count), maxChars)
        let opts = UInt32(o)
        let hasRect = opts & (etoOpaque | etoClipped) != 0
        let rect: R4? = hasRect ? R4(i16s(r, 14), i16s(r, 16), i16s(r, 18), i16s(r, 20)) : nil
        let at = hasRect ? 22 : 14
        // A string running past the record is cut to what the record holds.
        n = Swift.min(n, Swift.max(r.count - at, 0))
        guard let bytes = r.slice(at, n) else { return }
        let dxAt = at + (n + 1) / 2 * 2
        let dx: [Float] = r.count >= dxAt + 2 * n ? (0 ..< n).compactMap { r.i16(dxAt + 2 * $0).map(Float.init) } : []
        let (text, adv) = decodeBytes(bytes.array, cv.fontCharset, dx)
        cv.text(P(Double(x), Double(y)), text, adv, opts, rect)
    }

    /// TEXTOUT (MS-WMF 2.3.3.20): string length, the string padded to a word, then y and x.
    private static func textOut(_ cv: inout Canvas, _ r: Bytes) {
        guard let count = r.u16(6) else { return }
        let n = Swift.min(Int(count), maxChars)
        guard let bytes = r.slice(8, n) else { return }
        let at = 8 + (n + 1) / 2 * 2
        guard let y = r.i16(at), let x = r.i16(at + 2) else { return }
        let (text, _) = decodeBytes(bytes.array, cv.fontCharset, [])
        cv.text(P(Double(x), Double(y)), text, [], 0, nil)
    }

    /// (x, y) from a Y-then-X pair stored at `off`.
    private static func xy16(_ r: Bytes, _ off: Int) -> P? {
        guard let y = r.i16(off), let x = r.i16(off + 2) else { return nil }
        return P(Double(x), Double(y))
    }

    /// Rectangle stored as bottom, right, top, left (the order MS-WMF uses for RECTANGLE and ELLIPSE).
    private static func rect16(_ r: Bytes, _ off: Int) -> R4? {
        guard let b = r.i16(off), let rr = r.i16(off + 2), let t = r.i16(off + 4), let l = r.i16(off + 6) else { return nil }
        return R4(Double(l), Double(t), Double(rr), Double(b))
    }

    /// ARC, PIE and CHORD: end Y, end X, start Y, start X, then the bounding rectangle (bottom, right, top, left).
    private static func arc16(_ r: Bytes) -> (R4, P, P)? {
        guard let end = xy16(r, 6), let start = xy16(r, 10), let bounds = rect16(r, 14) else { return nil }
        return (bounds, start, end)
    }

    /// A count of 16-bit points, then the points (POLYLINE, POLYGON).
    private static func countedPoints(_ r: Bytes) -> [P]? {
        guard let n = r.u16(6) else { return nil }
        return r.tail(8)?.points(0, Int(n), wide: false)
    }

    /// POLYPOLYGON: polygon count, one 16-bit point count per polygon, then all points.
    private static func polypolygon(_ r: Bytes) -> [Op]? {
        guard let n16 = r.u16(6) else { return nil }
        let n = Int(n16)
        var counts: [Int] = []
        counts.reserveCapacity(n)
        for i in 0 ..< n {
            guard let c = r.u16(i * 2 + 8) else { return nil }
            counts.append(Int(c))
        }
        let total = counts.reduce(0, +)
        if total > Metafile.maxPathOps { return nil }
        guard let pts = r.tail(n * 2 + 8)?.points(0, total, wide: false) else { return nil }
        return subpaths(pts, counts, close: true)
    }

    /// Whether a DIBBITBLT or DIBSTRETCHBLT record carries a bitmap: without one it is exactly
    /// `(function >> 8) + 3` words long (MS-WMF 2.3.1.2, 2.3.1.3).
    private static func hasBitmap(_ fn: UInt16, _ r: Bytes) -> Bool {
        r.count / 2 > Int(fn >> 8) + 3
    }

    /// META_DIBBITBLT: rop(4), ySrc, xSrc, then height, width, yDest, xDest and the DIB at 22. The bitmap-less
    /// form has a reserved word before the height, so its fields sit 2 bytes later; it, or a source-less raster
    /// operation, fills the destination.
    private static func dibBitBlt(_ cv: inout Canvas, _ r: Bytes) {
        guard let rop = r.u32(6) else { return }
        if !hasBitmap(0x0940, r) {
            return cv.fillRop(R4(i16s(r, 22), i16s(r, 20), i16s(r, 18), i16s(r, 16)), rop)
        }
        let dst = R4(i16s(r, 20), i16s(r, 18), i16s(r, 16), i16s(r, 14))
        if Canvas.sourceless(rop) { return cv.fillRop(dst, rop) }
        let src = R4(i16s(r, 12), i16s(r, 10), dst[2], dst[3])
        dibBlit(&cv, r, 22, rop, dst, src)
    }

    /// META_DIBSTRETCHBLT: rop(4), srcH, srcW, ySrc, xSrc, then destH, destW, yDest, xDest and the DIB at 26. The
    /// bitmap-less form has a reserved word after xSrc, so the destination sits 2 bytes later; it, or a
    /// source-less raster operation, fills the destination.
    private static func dibStretchBlt(_ cv: inout Canvas, _ r: Bytes) {
        guard let rop = r.u32(6) else { return }
        if !hasBitmap(0x0B41, r) {
            return cv.fillRop(R4(i16s(r, 26), i16s(r, 24), i16s(r, 22), i16s(r, 20)), rop)
        }
        let dst = R4(i16s(r, 24), i16s(r, 22), i16s(r, 20), i16s(r, 18))
        if Canvas.sourceless(rop) { return cv.fillRop(dst, rop) }
        let src = R4(i16s(r, 16), i16s(r, 14), i16s(r, 12), i16s(r, 10))
        dibBlit(&cv, r, 26, rop, dst, src)
    }

    /// A DIB at `at`, stretched from source rectangle `src` into `dst` (both in logical units, pixels for `src`).
    /// The raster operation `rop` decides how the pixels combine (see `DIB.prepare`).
    private static func dibBlit(_ cv: inout Canvas, _ r: Bytes, _ at: Int, _ rop: UInt32, _ dst: R4, _ src: R4) {
        guard let dib = r.tail(at), let n = DIB.infoLen(dib), let info = dib.slice(0, n), let bits = dib.tail(n),
              var img = DIB.decode(info, bits, keepAlpha: false)
        else { return }
        DIB.prepare(&img, .rop(rop))
        let s = [Int64(rustCast: src[0]), Int64(rustCast: src[1]), Int64(rustCast: src[2]), Int64(rustCast: src[3])]
        guard let (cropped, d) = DIB.clipBlit(img, s, dst) else { return }
        cv.bitmap(d, cropped)
    }
}
