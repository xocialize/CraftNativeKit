// CNMetafile — compressed EMF+ bitmaps (PNG, JPEG, GIF, TIFF, BMP) decoded to straight RGBA8 with ImageIO, where
// deckcraft's crates/metafile/src/emfplus.rs `decode_compressed` uses the `image` crate (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors). The same limits apply: 32768 pixels a side and
// `Metafile.maxPixels` in all, checked from the header before anything is decoded.
import CoreGraphics
import Foundation
import ImageIO

private let maxSide = 1 << 15

/// The first image of a compressed file as top-down RGBA8, or nil when it cannot be read or is too large.
func decodeCompressedImage(_ bytes: [UInt8]) -> Rgba? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, options), CGImageSourceGetCount(source) > 0,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
          let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    guard pw > 0, ph > 0, pw <= maxSide, ph <= maxSide, pw * ph <= Metafile.maxPixels else { return nil }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, options), image.width == pw, image.height == ph else { return nil }
    return rawRGBA(image) ?? drawnRGBA(image)
}

/// The decoded samples as they are, for the 8-bit RGB, RGBA and grey layouts ImageIO produces: no colour matching,
/// as the `image` crate does none.
private func rawRGBA(_ image: CGImage) -> Rgba? {
    guard image.bitsPerComponent == 8, let model = image.colorSpace?.model, model == .rgb || model == .monochrome,
          let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
    let (w, h, stride, bpp) = (image.width, image.height, image.bytesPerRow, image.bitsPerPixel / 8)
    guard CFDataGetLength(data) >= stride * (h - 1) + w * bpp else { return nil }
    let alpha = image.alphaInfo
    let order = image.bitmapInfo.intersection(.byteOrderMask)
    let little = order == .byteOrder32Little || order == .byteOrder16Little
    // Channel offsets within a pixel, as stored in memory.
    let r, g, b: Int
    var a: Int?
    var premultiplied = false
    switch (model, bpp, alpha) {
    case (.monochrome, 1, .none):
        (r, g, b) = (0, 0, 0)
    case (.monochrome, 2, .last), (.monochrome, 2, .premultipliedLast):
        (r, g, b, a) = (0, 0, 0, 1)
        premultiplied = alpha == .premultipliedLast
    case (.rgb, 3, .none):
        (r, g, b) = (0, 1, 2)
    case (.rgb, 4, .last), (.rgb, 4, .premultipliedLast), (.rgb, 4, .noneSkipLast):
        (r, g, b) = little ? (3, 2, 1) : (0, 1, 2)
        if alpha != .noneSkipLast { a = little ? 0 : 3 }
        premultiplied = alpha == .premultipliedLast
    case (.rgb, 4, .first), (.rgb, 4, .premultipliedFirst), (.rgb, 4, .noneSkipFirst):
        (r, g, b) = little ? (2, 1, 0) : (1, 2, 3)
        if alpha != .noneSkipFirst { a = little ? 3 : 0 }
        premultiplied = alpha == .premultipliedFirst
    default:
        return nil
    }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0 ..< h {
        let row = base + y * stride
        for x in 0 ..< w {
            let p = row + x * bpp
            let o = (y * w + x) * 4
            let av = a.map { p[$0] } ?? 255
            (px[o], px[o + 1], px[o + 2], px[o + 3]) = (p[r], p[g], p[b], av)
            if premultiplied { unpremultiply(&px, o) }
        }
    }
    return Rgba(w: w, h: h, bottomUp: false, px: px)
}

/// Any other layout, drawn into an RGBA8 context (premultiplied, as CoreGraphics draws) and made straight again.
private func drawnRGBA(_ image: CGImage) -> Rgba? {
    let (w, h) = (image.width, image.height)
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(
            data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }
    var o = 0
    while o < px.count {
        unpremultiply(&px, o)
        o += 4
    }
    return Rgba(w: w, h: h, bottomUp: false, px: px)
}

private func unpremultiply(_ px: inout [UInt8], _ o: Int) {
    let a = UInt32(px[o + 3])
    if a == 0 || a == 255 { return }
    for c in o ..< o + 3 { px[c] = UInt8(Swift.min((UInt32(px[c]) * 255 + a / 2) / a, 255)) }
}
