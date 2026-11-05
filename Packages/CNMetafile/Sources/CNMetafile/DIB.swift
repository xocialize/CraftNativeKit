// CNMetafile — device-independent bitmaps. BITMAPINFOHEADER DIBs at 1/4/8/16/24/32 bpp with BI_RGB or BI_BITFIELDS
// decode to RGBA8 rows, top-down. Compressed (RLE, JPEG, PNG) and V4/V5-only features are not decoded. Port of
// deckcraft crates/metafile/src/dib.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
// `decodeClip` and `clipRect` are from WordCraft crates/metafile/src/dib.rs at fd7f6621 (MIT OR Apache-2.0, ©
// ArtCraft Team and the WordCraft contributors) (45d2546b); the side cap in `decodeClip` (991a21de) and the row
// decoders chosen once per bitmap (`RowKind`, `Channel`; c38cd8c4) are from the same file at 5a4c45e7.

private let biRGB: UInt32 = 0
private let biBitfields: UInt32 = 3
/// Most palette entries a DIB can carry (the colour table never exceeds 2^8).
private let maxPalette = 256
private let ropSrcAnd: UInt32 = 0x0088_00C6
private let ropSrcPaint: UInt32 = 0x00EE_0086
private let ropSrcInvert: UInt32 = 0x0066_0046

/// A decoded picture. `bottomUp` records the DIB's native row order, which source rectangles use.
struct Rgba {
    var w: Int
    var h: Int
    var bottomUp: Bool
    var px: [UInt8]
}

/// How a decoded bitmap combines with the destination.
enum Blend {
    /// A raster operation (BITBLT, STRETCHDIB and friends).
    case rop(UInt32)
    /// EMR_ALPHABLEND: a constant alpha (0...255), times the per-pixel alpha when `perPixel` is set
    /// (AC_SRC_ALPHA: the source colours are premultiplied by it).
    case alpha(constant: UInt8, perPixel: Bool)

    /// Whether the decoder must keep the 32-bit alpha byte of each pixel.
    var perPixel: Bool {
        if case .alpha(_, true) = self { return true }
        return false
    }
}

/// The fields of a BITMAPINFOHEADER every decode needs (internal for the tests' per-pixel reference decoder).
struct Header {
    var w: Int
    var h: Int
    var topDown: Bool
    var bpp: Int
    var masks: (UInt32, UInt32, UInt32)
    var palOff: Int
    var palN: Int

    static func read(_ info: Bytes) -> Header? {
        guard let size32 = info.u32(0), let w = info.i32(4), let h = info.i32(8), let bpp16 = info.u16(14),
              let comp = info.u32(16), let clrUsed32 = info.u32(32) else { return nil }
        let size = Int(size32)
        let bpp = Int(bpp16)
        let clrUsed = Int(clrUsed32)
        guard size >= 40, w > 0, h != 0, [1, 4, 8, 16, 24, 32].contains(bpp), comp == biRGB || comp == biBitfields else {
            return nil
        }
        let masks: (UInt32, UInt32, UInt32)
        if comp == biBitfields {
            guard let r = info.u32(40), let g = info.u32(44), let b = info.u32(48) else { return nil }
            masks = (r, g, b)
        } else if bpp == 16 {
            masks = (0x7C00, 0x03E0, 0x001F)
        } else {
            masks = (0xFF_0000, 0xFF00, 0xFF)
        }
        let masksLen = comp == biBitfields && size == 40 ? 12 : 0
        let (palOff, overflow) = size.addingReportingOverflow(masksLen)
        guard !overflow else { return nil }
        // Indexed formats take 2^bpp entries when clrUsed is 0. Deeper formats carry only the entries clrUsed
        // names (WMF DIBs can have them), still capped.
        let palN: Int = if bpp <= 8 {
            clrUsed == 0 ? 1 << bpp : Swift.min(clrUsed, 1 << bpp)
        } else {
            Swift.min(clrUsed, maxPalette)
        }
        return Header(w: Int(w), h: Int(h.magnitude), topDown: h < 0, bpp: bpp, masks: masks, palOff: palOff, palN: palN)
    }
}

enum DIB {
    /// Byte length of the info part (header, masks, palette) of a DIB, so the pixel bits follow it.
    static func infoLen(_ dib: Bytes) -> Int? {
        guard let h = Header.read(dib) else { return nil }
        let (pal, o1) = h.palN.multipliedReportingOverflow(by: 4)
        let (len, o2) = h.palOff.addingReportingOverflow(pal)
        return o1 || o2 ? nil : len
    }

    /// Decodes a DIB given as its info part (header plus masks and palette) and its pixel bits. The 32-bit alpha
    /// byte is kept only when `keepAlpha` is set (per-pixel alpha blends); otherwise pixels are opaque.
    static func decode(_ info: Bytes, _ bits: Bytes, keepAlpha: Bool) -> Rgba? {
        guard let v = Validated(info, bits) else { return nil }
        let whole = Span(x0: 0, x1: v.hd.w, r0: 0, r1: v.hd.h)
        var decoded = 0
        guard let px = decodeSpan(v, whole, keepAlpha, &decoded) else { return nil }
        return Rgba(w: v.hd.w, h: v.hd.h, bottomUp: !v.hd.topDown, px: px)
    }

    /// Decodes the part of a DIB that the source rectangle `src` = `[x, y, w, h]` selects and returns it (top-down)
    /// with the part of the destination `dst` that it fills; see `clipRect` for the coordinates. `info` is the info
    /// part (header plus masks and palette) and `bits` the pixel bits; `keepAlpha` as for `decode`. Only the clipped
    /// rows and columns are decoded, so the work and the memory follow the crop, not the whole bitmap; the whole
    /// bitmap is still validated (size cap, palette, bits length). Gives what `decode` then `clipBlit` gives, except
    /// that it is nil as well when the clipped width or height is over `Metafile.maxBitmapSide`, which no renderer
    /// draws.
    static func decodeClip(_ info: Bytes, _ bits: Bytes, keepAlpha: Bool, _ src: [Int64], _ dst: R4) -> (Rgba, R4)? {
        var decoded = 0
        return decodeClip(info, bits, keepAlpha: keepAlpha, src, dst, decoded: &decoded)
    }

    /// `decodeClip`, adding the number of pixels decoded to `decoded` (the tests check that it follows the crop).
    static func decodeClip(_ info: Bytes, _ bits: Bytes, keepAlpha: Bool, _ src: [Int64], _ dst: R4, decoded: inout Int) -> (Rgba, R4)? {
        guard let v = Validated(info, bits),
              let (span, out) = clipRect(w: v.hd.w, h: v.hd.h, bottomUp: !v.hd.topDown, src, dst)
        else { return nil }
        // The renderers draw no bitmap with a side over the cap (`takePixels`); decoding one would only fill the
        // parse's memory budget with pixels nobody draws.
        let cap = Int(Metafile.maxBitmapSide)
        guard span.x1 - span.x0 <= cap, span.r1 - span.r0 <= cap, let px = decodeSpan(v, span, keepAlpha, &decoded) else {
            return nil
        }
        return (Rgba(w: span.x1 - span.x0, h: span.r1 - span.r0, bottomUp: false, px: px), out)
    }

    /// A DIB whose header, size, palette and bits length passed the checks every decode makes first.
    private struct Validated {
        let hd: Header
        let stride: Int
        /// The pixel bits, `stride × h` bytes, as a view of the shared buffer.
        let data: Bytes
        let palette: [UInt8]

        init?(_ info: Bytes, _ bits: Bytes) {
            guard let hd = Header.read(info) else { return nil }
            let (pixels, o1) = hd.w.multipliedReportingOverflow(by: hd.h)
            guard !o1, pixels > 0, pixels <= Metafile.maxPixels else { return nil }
            let (wb, o2) = hd.w.multipliedReportingOverflow(by: hd.bpp)
            let (wb31, o3) = wb.addingReportingOverflow(31)
            guard !o2, !o3 else { return nil }
            let stride = wb31 / 32 * 4
            let (dataLen, o4) = stride.multipliedReportingOverflow(by: hd.h)
            guard !o4, let data = bits.slice(0, dataLen), let pal = info.slice(hd.palOff, hd.palN * 4) else { return nil }
            (self.hd, self.stride, self.data, palette) = (hd, stride, data, pal.array)
        }
    }

    /// The columns `x0..<x1` and top-down rows `r0..<r1` of a bitmap that a clipped source rectangle covers.
    struct Span {
        var x0: Int
        var x1: Int
        var r0: Int
        var r1: Int
    }

    /// Decodes the pixels of `span` (top-down rows), adding the number asked of the decoder to `decoded`.
    private static func decodeSpan(_ v: Validated, _ span: Span, _ keepAlpha: Bool, _ decoded: inout Int) -> [UInt8]? {
        let hd = v.hd
        let (ow, oh) = (span.x1 - span.x0, span.r1 - span.r0)
        let (n, o1) = ow.multipliedReportingOverflow(by: oh)
        let (len, o2) = n.multipliedReportingOverflow(by: 4)
        guard ow > 0, oh > 0, !o1, !o2, span.x0 >= 0, span.r0 >= 0, span.r1 <= hd.h else { return nil }
        decoded += n
        // The depth, palette and masks are the same for every pixel: pick the row decoder once.
        let kind = RowKind(hd, v.palette, keepAlpha)
        let (d, base) = (v.data.buffer, v.data.start)
        var px = [UInt8](repeating: 0, count: len)
        var o = 0
        for y in span.r0 ..< span.r1 {
            // One source row, all of its bytes; `Validated` checked that the rows lie inside the bits.
            let row = base + (hd.topDown ? y : hd.h - 1 - y) * v.stride
            guard row >= 0, row + v.stride <= d.count,
                  kind.decodeRow(d, row: row, stride: v.stride, cols: span.x0 ..< span.x1, into: &px, at: o) else { return nil }
            o += ow * 4
        }
        return px
    }

    /// Palette entries are BGRX quads; an index past the table reads as black rather than failing the image.
    static func palette(_ pal: [UInt8], _ i: Int) -> (UInt8, UInt8, UInt8) {
        guard i >= 0, i * 4 + 4 <= pal.count else { return (0, 0, 0) }
        return (pal[i * 4 + 2], pal[i * 4 + 1], pal[i * 4])
    }

    /// Clips a source rectangle `src` = `[x, y, w, h]` to a `w` × `h` bitmap and returns the columns and top-down
    /// rows it covers with the part of the destination `dst` that they fill. `src` is in DIB pixel coordinates (`y`
    /// counted from the DIB's origin, so bottom-up images count from the bottom); a non-positive source size means
    /// the whole bitmap. Clipping shrinks the destination by the same ratio and shifts it by the clipped-off part,
    /// so the rest of the image keeps its place. A negative destination extent is kept (the caller mirrors). nil
    /// when nothing of the bitmap is covered.
    static func clipRect(w: Int, h: Int, bottomUp: Bool, _ src: [Int64], _ dst: R4) -> (Span, R4)? {
        let (iw, ih) = (Int64(w), Int64(h))
        let s = src.count == 4 && src[2] > 0 && src[3] > 0 ? src : [0, 0, iw, ih]
        let (sx, sy, sw, sh) = (s[0], s[1], s[2], s[3])
        // The request's top row in top-down order.
        let top = bottomUp ? ih.subtractingSaturating(sy).subtractingSaturating(sh) : sy
        let (x0, x1) = (Swift.max(sx, 0), Swift.min(sx.addingSaturating(sw), iw))
        let (r0, r1) = (Swift.max(top, 0), Swift.min(top.addingSaturating(sh), ih))
        guard x1 > x0, r1 > r0 else { return nil }
        let (kx, ky) = (dst[2] / Double(sw), dst[3] / Double(sh))
        let out = R4(dst[0] + Double(x0 - sx) * kx, dst[1] + Double(r0 - top) * ky, Double(x1 - x0) * kx, Double(r1 - r0) * ky)
        return (Span(x0: Int(x0), x1: Int(x1), r0: Int(r0), r1: Int(r1)), out)
    }

    /// Clips a source rectangle to a decoded bitmap (see `clipRect`) and returns the cropped pixels (top-down) with
    /// the part of the destination that they fill.
    static func clipBlit(_ img: Rgba, _ src: [Int64], _ dst: R4) -> (Rgba, R4)? {
        guard let (c, out) = clipRect(w: img.w, h: img.h, bottomUp: img.bottomUp, src, dst) else { return nil }
        let (ow, oh) = (c.x1 - c.x0, c.r1 - c.r0)
        var px: [UInt8] = []
        px.reserveCapacity(ow * oh * 4)
        for row in c.r0 ..< c.r1 {
            let st = (row * img.w + c.x0) * 4
            guard st + ow * 4 <= img.px.count else { return nil }
            px.append(contentsOf: img.px[st ..< st + ow * 4])
        }
        return (Rgba(w: ow, h: oh, bottomUp: false, px: px), out)
    }

    /// Applies a blend to decoded pixels before they are drawn. The picture has no destination pixels, so raster
    /// operations are drawn as they look over white paper: SRCAND (destination AND source) leaves white source
    /// pixels out and draws the rest; SRCPAINT and SRCINVERT leave black ones out. Other operations draw the source
    /// as copied. Constant alpha scales every pixel's alpha, after a per-pixel (premultiplied) source is made
    /// straight.
    static func prepare(_ img: inout Rgba, _ blend: Blend) {
        switch blend {
        case .rop(ropSrcAnd):
            clearWhere(&img, 255, 255, 255)
        case .rop(ropSrcPaint), .rop(ropSrcInvert):
            clearWhere(&img, 0, 0, 0)
        case .rop:
            break
        case .alpha(let constant, let perPixel):
            var i = 0
            while i + 4 <= img.px.count {
                if perPixel { unpremultiply(&img.px, i) }
                img.px[i + 3] = UInt8(truncatingIfNeeded: UInt16(img.px[i + 3]) * UInt16(constant) / 255)
                i += 4
            }
        }
    }

    /// Makes the pixels of colour `rgb` transparent: where a raster operation keeps the destination.
    private static func clearWhere(_ img: inout Rgba, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        var i = 0
        while i + 4 <= img.px.count {
            if img.px[i] == r && img.px[i + 1] == g && img.px[i + 2] == b { img.px[i + 3] = 0 }
            i += 4
        }
    }

    /// AC_SRC_ALPHA sources are premultiplied; the model holds straight RGBA, so divide the colour by the alpha
    /// (rounded, capped at 255). A transparent pixel keeps its colour bytes.
    private static func unpremultiply(_ px: inout [UInt8], _ i: Int) {
        let a = UInt32(px[i + 3])
        if a == 0 || a == 255 { return }
        for c in i ..< i + 3 {
            px[c] = UInt8(Swift.min((UInt32(px[c]) * 255 + a / 2) / a, 255))
        }
    }

    /// Mirrors a decoded image left-right and/or top-bottom. Rows come from the buffer as chunks, so a short
    /// buffer flips only the rows it has.
    static func flip(_ img: inout Rgba, horizontal: Bool, vertical: Bool) {
        let (w, h) = (img.w, img.h)
        if w == 0 || h == 0 { return }
        let row = w * 4
        if horizontal {
            let rows = img.px.count / row
            for r in 0 ..< rows {
                let base = r * row
                for x in 0 ..< w / 2 {
                    for c in 0 ..< 4 { img.px.swapAt(base + x * 4 + c, base + (w - 1 - x) * 4 + c) }
                }
            }
        }
        if vertical {
            // Rows the buffer actually holds: a short buffer flips only those.
            let n = Swift.min(h, img.px.count / row)
            for y in 0 ..< n / 2 {
                let (a, b) = (y * row, (n - 1 - y) * row)
                for k in 0 ..< row { img.px.swapAt(a + k, b + k) }
            }
        }
    }
}

/// One channel of a masked 16/32 bpp pixel, with the shift and scale worked out once per bitmap. Channels of up to
/// 8 bits (every common 16 bpp layout) go through a table of their values, so a pixel costs no division.
private struct Channel {
    let mask: UInt32
    let shift: UInt32
    let max: UInt64
    /// The 8-bit value of every channel value `0...max` when `max <= 255`.
    let table: [UInt8]

    init(_ mask: UInt32) {
        let shift = mask == 0 ? 0 : UInt32(mask.trailingZeroBitCount)
        let max = UInt64(mask >> shift)
        var table = [UInt8](repeating: 0, count: 256)
        if mask != 0 && max <= 255 {
            for val in 0 ... Int(max) {
                table[val] = UInt8(truncatingIfNeeded: (UInt64(val) * 255 + max / 2) / max)
            }
        }
        (self.mask, self.shift, self.max, self.table) = (mask, shift, max, table)
    }

    /// The channel of `v` scaled to 8 bits; 0 when the mask is empty.
    @inline(__always)
    func get(_ v: UInt32) -> UInt8 {
        if mask == 0 { return 0 }
        let val = UInt64((v & mask) >> shift)
        // `val <= max`, so a table index is at most 255.
        if max <= 255 { return table[Int(val)] }
        return UInt8(truncatingIfNeeded: (val * 255 + max / 2) / max)
    }
}

/// How the pixels of one DIB turn into RGBA, decided once from its header.
private enum RowKind {
    /// 1, 4 or 8 bpp: `bpp` bits per index into a table of every possible index (RGBA quads).
    case indexed(bpp: Int, table: [UInt8])
    /// 24 bpp: BGR triples.
    case bgr24
    /// 32 bpp with the default masks: BGRA quads, alpha kept or forced opaque.
    case bgra32(keepAlpha: Bool)
    /// 16 bpp, or 32 bpp with other masks.
    case masked(bpp: Int, r: Channel, g: Channel, b: Channel, keepAlpha: Bool)

    init(_ hd: Header, _ pal: [UInt8], _ keepAlpha: Bool) {
        switch hd.bpp {
        case 1, 4, 8:
            // An index past the palette reads as black, as in `palette`.
            var table = [UInt8](repeating: 0, count: 256 * 4)
            for i in 0 ..< 256 {
                let c = i < 1 << hd.bpp ? DIB.palette(pal, i) : (0, 0, 0)
                (table[i * 4], table[i * 4 + 1], table[i * 4 + 2], table[i * 4 + 3]) = (c.0, c.1, c.2, 255)
            }
            self = .indexed(bpp: hd.bpp, table: table)
        case 24:
            self = .bgr24
        case 32 where hd.masks == (0xFF_0000, 0xFF00, 0xFF):
            self = .bgra32(keepAlpha: keepAlpha)
        default:
            self = .masked(bpp: hd.bpp, r: Channel(hd.masks.0), g: Channel(hd.masks.1), b: Channel(hd.masks.2), keepAlpha: keepAlpha)
        }
    }

    /// Decodes the columns `cols` of the source row of `stride` bytes at `row` in `d` into `px` from `at`. The caller
    /// checked that the row lies inside `d` and `px` has room for the columns; false when the row is shorter than
    /// the columns need.
    func decodeRow(_ d: [UInt8], row: Int, stride: Int, cols: Range<Int>, into px: inout [UInt8], at start: Int) -> Bool {
        var o = start
        switch self {
        case .indexed(let bpp, let table):
            // The last column's byte must lie inside the row.
            guard cols.upperBound * bpp <= stride * 8 else { return false }
            let mask = (1 << bpp) - 1
            for x in cols {
                let bit = x * bpp
                let k = (Int(d[row + bit / 8]) >> (8 - bpp - bit % 8) & mask) * 4
                (px[o], px[o + 1], px[o + 2], px[o + 3]) = (table[k], table[k + 1], table[k + 2], 255)
                o += 4
            }
        case .bgr24:
            guard cols.upperBound * 3 <= stride else { return false }
            for x in cols {
                let s = row + x * 3
                (px[o], px[o + 1], px[o + 2], px[o + 3]) = (d[s + 2], d[s + 1], d[s], 255)
                o += 4
            }
        case .bgra32(let keepAlpha):
            guard cols.upperBound * 4 <= stride else { return false }
            for x in cols {
                let s = row + x * 4
                (px[o], px[o + 1], px[o + 2], px[o + 3]) = (d[s + 2], d[s + 1], d[s], keepAlpha ? d[s + 3] : 255)
                o += 4
            }
        case .masked(bpp: 16, let r, let g, let b, _):
            guard cols.upperBound * 2 <= stride else { return false }
            for x in cols {
                let s = row + x * 2
                let v = UInt32(d[s]) | UInt32(d[s + 1]) << 8
                (px[o], px[o + 1], px[o + 2], px[o + 3]) = (r.get(v), g.get(v), b.get(v), 255)
                o += 4
            }
        case .masked(_, let r, let g, let b, let keepAlpha):
            guard cols.upperBound * 4 <= stride else { return false }
            for x in cols {
                let s = row + x * 4
                let v = UInt32(d[s]) | UInt32(d[s + 1]) << 8 | UInt32(d[s + 2]) << 16 | UInt32(d[s + 3]) << 24
                (px[o], px[o + 1], px[o + 2], px[o + 3]) = (r.get(v), g.get(v), b.get(v), keepAlpha ? UInt8(truncatingIfNeeded: v >> 24) : 255)
                o += 4
            }
        }
        return true
    }
}

extension Int64 {
    /// Rust's `saturating_add`.
    func addingSaturating(_ o: Int64) -> Int64 {
        let (v, overflow) = addingReportingOverflow(o)
        return overflow ? (o > 0 ? .max : .min) : v
    }

    /// Rust's `saturating_sub`.
    func subtractingSaturating(_ o: Int64) -> Int64 {
        let (v, overflow) = subtractingReportingOverflow(o)
        return overflow ? (o < 0 ? .max : .min) : v
    }
}
