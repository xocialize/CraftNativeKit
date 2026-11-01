// CNMetafile — device-independent bitmaps. BITMAPINFOHEADER DIBs at 1/4/8/16/24/32 bpp with BI_RGB or
// BI_BITFIELDS decode to RGBA8 rows, top-down. Compressed (RLE, JPEG, PNG) and V4/V5-only features are not
// decoded. Port of deckcraft crates/metafile/src/dib.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).

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

private struct Header {
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
        guard let hd = Header.read(info) else { return nil }
        let (pixels, o1) = hd.w.multipliedReportingOverflow(by: hd.h)
        guard !o1, pixels > 0, pixels <= Metafile.maxPixels else { return nil }
        let (wb, o2) = hd.w.multipliedReportingOverflow(by: hd.bpp)
        let (wb31, o3) = wb.addingReportingOverflow(31)
        guard !o2, !o3 else { return nil }
        let stride = wb31 / 32 * 4
        let (dataLen, o4) = stride.multipliedReportingOverflow(by: hd.h)
        guard !o4, let data = bits.slice(0, dataLen), let pal = info.slice(hd.palOff, hd.palN * 4) else { return nil }
        let d = data.array
        let palette = pal.array
        var px = [UInt8](repeating: 0, count: pixels * 4)
        if hd.bpp <= 8 {
            // Indexed: every possible index looked up once (missing entries are black).
            var lut = [UInt8](repeating: 0, count: 256 * 4)
            for i in 0 ..< 256 {
                let c = Self.palette(palette, i)
                (lut[i * 4], lut[i * 4 + 1], lut[i * 4 + 2], lut[i * 4 + 3]) = (c.0, c.1, c.2, 255)
            }
            let (bpp, mask) = (hd.bpp, UInt8(truncatingIfNeeded: (1 << hd.bpp) - 1))
            for y in 0 ..< hd.h {
                let row = (hd.topDown ? y : hd.h - 1 - y) * stride
                var o = y * hd.w * 4
                for x in 0 ..< hd.w {
                    let bit = x * bpp
                    guard let b = byteAt(d, row + bit / 8) else { return nil }
                    let k = Int((b >> UInt8(8 - bpp - bit % 8)) & mask) * 4
                    (px[o], px[o + 1], px[o + 2], px[o + 3]) = (lut[k], lut[k + 1], lut[k + 2], 255)
                    o += 4
                }
            }
            return Rgba(w: hd.w, h: hd.h, bottomUp: !hd.topDown, px: px)
        }
        for y in 0 ..< hd.h {
            let srcRow = hd.topDown ? y : hd.h - 1 - y
            let row = srcRow * stride
            for x in 0 ..< hd.w {
                guard let p = pixel(d, row, x, hd, palette, keepAlpha) else { return nil }
                let o = (y * hd.w + x) * 4
                px[o] = p.0
                px[o + 1] = p.1
                px[o + 2] = p.2
                px[o + 3] = p.3
            }
        }
        return Rgba(w: hd.w, h: hd.h, bottomUp: !hd.topDown, px: px)
    }

    private static func pixel(_ data: [UInt8], _ row: Int, _ x: Int, _ hd: Header, _ pal: [UInt8], _ keepAlpha: Bool) -> (UInt8, UInt8, UInt8, UInt8)? {
        let (mR, mG, mB) = hd.masks
        let rgb: (UInt8, UInt8, UInt8)
        switch hd.bpp {
        case 1:
            guard let b = byteAt(data, row + x / 8) else { return nil }
            rgb = palette(pal, Int((b >> (7 - UInt8(x % 8))) & 1))
        case 4:
            guard let b = byteAt(data, row + x / 2) else { return nil }
            rgb = palette(pal, Int(x % 2 == 0 ? b >> 4 : b & 0x0F))
        case 8:
            guard let b = byteAt(data, row + x) else { return nil }
            rgb = palette(pal, Int(b))
        case 24:
            guard let b = byteAt(data, row + x * 3), let g = byteAt(data, row + x * 3 + 1), let r = byteAt(data, row + x * 3 + 2) else { return nil }
            rgb = (r, g, b)
        case 16:
            let o = row + x * 2
            guard let lo = byteAt(data, o), let hi = byteAt(data, o + 1) else { return nil }
            let v = UInt32(lo) | UInt32(hi) << 8
            rgb = (field(v, mR), field(v, mG), field(v, mB))
        default:
            let o = row + x * 4
            guard let b0 = byteAt(data, o), let b1 = byteAt(data, o + 1), let b2 = byteAt(data, o + 2), let b3 = byteAt(data, o + 3) else { return nil }
            let v = UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24
            let a: UInt8 = keepAlpha ? UInt8(truncatingIfNeeded: v >> 24) : 255
            return (field(v, mR), field(v, mG), field(v, mB), a)
        }
        return (rgb.0, rgb.1, rgb.2, 255)
    }

    /// Palette entries are BGRX quads; an index past the table reads as black rather than failing the image.
    private static func palette(_ pal: [UInt8], _ i: Int) -> (UInt8, UInt8, UInt8) {
        guard i * 4 + 4 <= pal.count else { return (0, 0, 0) }
        return (pal[i * 4 + 2], pal[i * 4 + 1], pal[i * 4])
    }

    /// Extracts one channel from a masked pixel value and scales it to 8 bits.
    private static func field(_ v: UInt32, _ mask: UInt32) -> UInt8 {
        if mask == 0 { return 0 }
        let shift = UInt32(mask.trailingZeroBitCount)
        let max = UInt64(mask >> shift)
        let val = UInt64((v & mask) >> shift)
        return UInt8(truncatingIfNeeded: (val * 255 + max / 2) / max)
    }

    /// Clips a source rectangle `src` = `[x, y, w, h]` to the bitmap and returns the cropped pixels (top-down)
    /// with the part of the destination `dst` that they fill. `src` is in DIB pixel coordinates (`y` counted from
    /// the DIB's origin, so bottom-up images count from the bottom); a non-positive source size means the whole
    /// bitmap. Clipping shrinks the destination by the same ratio and shifts it by the clipped-off part, so the
    /// rest of the image keeps its place. A negative destination extent is kept (the caller mirrors).
    static func clipBlit(_ img: Rgba, _ src: [Int64], _ dst: R4) -> (Rgba, R4)? {
        let (iw, ih) = (Int64(img.w), Int64(img.h))
        let s = src.count == 4 && src[2] > 0 && src[3] > 0 ? src : [0, 0, iw, ih]
        let (sx, sy, sw, sh) = (s[0], s[1], s[2], s[3])
        // The request's top row in top-down order.
        let top = img.bottomUp ? ih.subtractingSaturating(sy).subtractingSaturating(sh) : sy
        let (x0, x1) = (Swift.max(sx, 0), Swift.min(sx.addingSaturating(sw), iw))
        let (r0, r1) = (Swift.max(top, 0), Swift.min(top.addingSaturating(sh), ih))
        guard x1 > x0, r1 > r0 else { return nil }
        let (kx, ky) = (dst[2] / Double(sw), dst[3] / Double(sh))
        let out = R4(dst[0] + Double(x0 - sx) * kx, dst[1] + Double(r0 - top) * ky, Double(x1 - x0) * kx, Double(r1 - r0) * ky)
        let (cx0, cx1, cr0, cr1) = (Int(x0), Int(x1), Int(r0), Int(r1))
        let (ow, oh) = (cx1 - cx0, cr1 - cr0)
        var px: [UInt8] = []
        px.reserveCapacity(ow * oh * 4)
        for row in cr0 ..< cr1 {
            let st = (row * img.w + cx0) * 4
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

/// `data[i]`, or nil past either end (a non-generic `at`, which stays fast in debug builds).
@inline(__always)
private func byteAt(_ data: [UInt8], _ i: Int) -> UInt8? {
    i >= 0 && i < data.count ? data[i] : nil
}
