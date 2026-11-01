// CNMetafile — reads Windows Metafiles (WMF) and Enhanced Metafiles (EMF, EMF+) into a neutral vector model of
// filled and stroked paths, pattern fills, RGBA bitmaps and text strings, in a picture frame with y down. Port of
// deckcraft crates/metafile/src/lib.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Text stays font-agnostic: a `MetafileText` item names the font the file asks for and carries the string, its
// advances and alignment; the renderer resolves the font and draws the glyphs.
//
// The reader works over byte arrays (no file system). Every read is bounds-checked and every count is capped;
// hostile input yields a shorter picture or a `MetafileError`, never a trap.
//
// Records follow MS-WMF and MS-EMF. Rectangle clip regions (`INTERSECTCLIPRECT`, `EXCLUDECLIPRECT`,
// `EXTSELECTCLIPRGN`) limit what later records draw. Records outside the supported set are skipped silently.
import CNCore
import Darwin

/// An RGBA8 colour, straight alpha.
public typealias MetafileColor = SIMD4<UInt8>

/// The entry points: `Metafile.parse` and `Metafile.isMetafile`.
public enum Metafile {
    /// Items kept from one file. Past the cap the parse stops and keeps what it has.
    static let maxItems = 200_000
    /// Object table slots (WMF handles, EMF object indices).
    static let maxObjects = 4096
    /// Largest bitmap in pixels (about 40 megapixels, 160 MB of RGBA).
    static let maxPixels = 40_000_000
    /// DC save-stack depth.
    static let maxStack = 1024
    /// Points in one open path bracket.
    static let maxPathOps = 2_000_000
    /// Bytes of path ops and pixels kept from one file (about 256 MB).
    static let maxBytes = 256 * 1024 * 1024

    /// SYMBOL_CHARSET: byte codes are the font's own symbol codes.
    public static let symbolCharset: UInt8 = 2
    /// Largest bitmap side the renderers draw: within the PDF image limit and the rasteriser's 16-bit sides.
    public static let maxBitmapSide: UInt32 = 30_000

    /// Parses a WMF (placeable or plain) or EMF file.
    public static func parse(_ bytes: [UInt8]) throws(MetafileError) -> MetafilePicture {
        try parse(Bytes(bytes), depth: 0)
    }

    /// `depth` counts metafile images being parsed inside metafile images, so a file of nested metafiles cannot
    /// run the stack out.
    static func parse(_ b: Bytes, depth: Int) throws(MetafileError) -> MetafilePicture {
        let (cv, frame): (Canvas, Frame?)
        if EMF.isEMF(b) {
            (cv, frame) = try EMF.parse(b, depth: depth)
        } else if WMF.isWMF(b) {
            // A WMF converted from an EMF can carry the original in MFCOMMENT escapes; PowerPoint draws the WMF's
            // own records (its dx rounding shows), so the copy is not used.
            (cv, frame) = try WMF.parse(b)
        } else {
            throw .notMetafile
        }
        return build(cv.items, frame)
    }

    /// True when the bytes start like a WMF (placeable or plain header) or an EMF.
    public static func isMetafile(_ bytes: [UInt8]) -> Bool {
        let b = Bytes(bytes)
        return EMF.isEMF(b) || WMF.isWMF(b)
    }

    /// Maps device-space output into the picture frame. Without a usable frame the frame is the bounding box of the
    /// drawing, so the origin is still the top-left of what was drawn.
    static func build(_ raw: [Raw], _ frame: Frame?) -> MetafilePicture {
        let frame = frame.flatMap { f in
            [f.rect[0], f.rect[1], f.rect[2], f.rect[3]].allSatisfy(\.isFinite) && f.rect[2] > 0 && f.rect[3] > 0 ? f : nil
        }
        let rect: R4
        let size: (Double, Double)
        if let f = frame {
            rect = f.rect
            size = f.size ?? (f.rect[2], f.rect[3])
        } else if let b = bbox(raw) {
            rect = R4(b[0], b[1], b[2] - b[0], b[3] - b[1])
            size = (b[2] - b[0], b[3] - b[1])
        } else {
            return MetafilePicture(width: 0, height: 0, items: [])
        }
        let sx = rect[2] > 0 ? size.0 / rect[2] : 1
        let sy = rect[3] > 0 ? size.1 / rect[3] : 1
        func tf(_ p: P) -> P { P((p.x - rect[0]) * sx, (p.y - rect[1]) * sy) }
        let strokeScale = (sx + sy) / 2
        // No stroke is wider than the picture's diagonal: anything wider is a mapping artefact.
        let diag = hypot(size.0, size.1)
        // Tiles shared by several fills stay shared. The raw tile is kept with its key, so the identifier is never
        // reused by another.
        var tiles: [ObjectIdentifier: (RawTile, MetafileTile)] = [:]
        var items: [MetafileItem] = []
        for r in raw {
            switch r {
            case .path(let ops, let fill, let stroke, let evenOdd, let region):
                guard let segs = segs(ops, tf), segs.count >= 2 else { continue }
                let s = stroke.flatMap { c, w in f((w * strokeScale).rustMin(diag)).map { MetafileStroke(color: c, width: $0) } }
                guard let region = mapRegion(region, tf) else { continue }
                items.append(.path(segs: segs, fill: fill, stroke: s, evenOdd: evenOdd, region: region))
            case .bitmap(let rr, let img, let region):
                let o = tf(P(rr[0], rr[1]))
                guard let x = f(o.x), let y = f(o.y), let w = f(rr[2] * sx), let h = f(rr[3] * sy),
                      let region = mapRegion(region, tf) else { continue }
                items.append(.bitmap(
                    rect: SIMD4(x, y, w, h), width: UInt32(truncatingIfNeeded: img.w), height: UInt32(truncatingIfNeeded: img.h),
                    rgba: img.px, region: region
                ))
            case .pattern(let ops, let evenOdd, let tile, let region):
                guard let segs = segs(ops, tf), segs.count >= 2 else { continue }
                let key = ObjectIdentifier(tile)
                let shared: MetafileTile
                if let (_, t) = tiles[key] {
                    shared = t
                } else {
                    let o = tf(P(0, 0))
                    guard let w = UInt32(exactly: tile.w), let h = UInt32(exactly: tile.h), let cx = f(tile.cell * sx),
                          let cy = f(tile.cell * sy), let ox = f(o.x), let oy = f(o.y) else { continue }
                    shared = MetafileTile(width: w, height: h, rgba: tile.px, cell: SIMD2(cx, cy), origin: SIMD2(ox, oy))
                    tiles[key] = (tile, shared)
                }
                guard let region = mapRegion(region, tf) else { continue }
                items.append(.pattern(segs: segs, evenOdd: evenOdd, tile: shared, region: region))
            case .text(var text, let region):
                // Device to picture: scale by (sx, sy) after moving the frame's corner to the origin.
                let m = text.transform
                let eg = tf(P(m[4], m[5]))
                text.transform = [m[0] * sx, m[1] * sy, m[2] * sx, m[3] * sy, eg.x, eg.y]
                guard text.transform.allSatisfy(\.isFinite) else { continue }
                if let c = text.clip {
                    let (p, q) = (tf(P(Double(c[0]), Double(c[1]))), tf(P(Double(c[2]), Double(c[3]))))
                    guard let x0 = f(p.x.rustMin(q.x)), let y0 = f(p.y.rustMin(q.y)), let x1 = f(p.x.rustMax(q.x)),
                          let y1 = f(p.y.rustMax(q.y)) else { continue }
                    text.clip = SIMD4(x0, y0, x1, y1)
                }
                guard let region = mapRegion(region, tf) else { continue }
                text.region = region
                items.append(.text(text))
            }
        }
        return MetafilePicture(width: f(size.0) ?? 0, height: f(size.1) ?? 0, items: items)
    }

    /// The region in picture units: `.some(nil)` is the default clip, nil a rectangle that does not map.
    private static func mapRegion(_ region: [R4]?, _ tf: (P) -> P) -> [SIMD4<Float>]?? {
        guard let rects = region else { return .some(nil) }
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(rects.count)
        for r in rects {
            let (p, q) = (tf(P(r[0], r[1])), tf(P(r[2], r[3])))
            guard let x0 = f(p.x.rustMin(q.x)), let y0 = f(p.y.rustMin(q.y)), let x1 = f(p.x.rustMax(q.x)),
                  let y1 = f(p.y.rustMax(q.y)) else { return nil }
            out.append(SIMD4(x0, y0, x1, y1))
        }
        return .some(out)
    }

    /// `v as f32` when that is finite.
    private static func f(_ v: Double) -> Float? {
        let v = Float(v)
        return v.isFinite ? v : nil
    }

    private static func segs(_ ops: [Op], _ tf: (P) -> P) -> [MetafileSeg]? {
        var out: [MetafileSeg] = []
        out.reserveCapacity(ops.count)
        func pt(_ p: P) -> (Float, Float)? {
            let q = tf(p)
            guard let x = f(q.x), let y = f(q.y) else { return nil }
            return (x, y)
        }
        for op in ops {
            switch op {
            case .m(let p):
                guard let (x, y) = pt(p) else { return nil }
                out.append(.move(x, y))
            case .l(let p):
                guard let (x, y) = pt(p) else { return nil }
                out.append(.line(x, y))
            case .c(let a, let b, let c):
                guard let (x1, y1) = pt(a), let (x2, y2) = pt(b), let (x3, y3) = pt(c) else { return nil }
                out.append(.cubic(x1, y1, x2, y2, x3, y3))
            case .z:
                out.append(.close)
            }
        }
        return out
    }

    /// Bounding box `[x0, y0, x1, y1]` over the finite points of the output.
    private static func bbox(_ raw: [Raw]) -> R4? {
        var b: R4?
        func grow(_ p: P) {
            guard p.isFinite else { return }
            b = b.map { R4($0[0].rustMin(p.x), $0[1].rustMin(p.y), $0[2].rustMax(p.x), $0[3].rustMax(p.y)) } ?? R4(p.x, p.y, p.x, p.y)
        }
        for r in raw {
            switch r {
            case .path(let ops, _, _, _, _), .pattern(let ops, _, _, _):
                for op in ops {
                    switch op {
                    case .m(let p), .l(let p): grow(p)
                    case .c(let a, let c, let d):
                        grow(a)
                        grow(c)
                        grow(d)
                    case .z: break
                    }
                }
            case .bitmap(let rect, _, _):
                grow(P(rect[0], rect[1]))
                grow(P(rect[0] + rect[2], rect[1] + rect[3]))
            case .text(let t, _):
                grow(P(t.transform[4], t.transform[5]))
            }
        }
        return b
    }
}

/// Why a file is not a picture.
public enum MetafileError: Error, Equatable, Sendable, CustomStringConvertible {
    case notMetafile
    case badHeader
    case noRecords

    public var description: String {
        switch self {
        case .notMetafile: "not a WMF or EMF file"
        case .badHeader: "metafile header is truncated or invalid"
        case .noRecords: "metafile has no readable records"
        }
    }
}

/// The picture frame in device units (`rect` = `[x, y, w, h]`) and, when the file states one, its size in picture
/// units.
struct Frame {
    var rect: R4
    var size: (Double, Double)?
}

/// A parsed metafile. Items use coordinates in `0..<width` and `0..<height`, y down.
public struct MetafilePicture: Equatable, Sendable {
    /// Size of the drawing in its own units: points for placeable WMF and EMF (from the frame), device or logical
    /// units otherwise.
    public var width: Float
    public var height: Float
    public var items: [MetafileItem]

    public init(width: Float, height: Float, items: [MetafileItem]) {
        self.width = width
        self.height = height
        self.items = items
    }
}

/// A stroke: colour and width in picture units (0 is a cosmetic hairline).
public struct MetafileStroke: Equatable, Sendable {
    public var color: MetafileColor
    public var width: Float

    public init(color: MetafileColor, width: Float) {
        self.color = color
        self.width = width
    }
}

public enum MetafileItem: Equatable, Sendable {
    /// A filled and/or stroked path, in picture coordinates. `region` is the clip region in picture units, each
    /// rectangle `[x0, y0, x1, y1]`; nil is the default clip.
    case path(segs: [MetafileSeg], fill: MetafileColor?, stroke: MetafileStroke?, evenOdd: Bool, region: [SIMD4<Float>]?)
    /// A bitmap stretched into `rect` = `[x, y, w, h]` (picture units), RGBA8 rows top-down.
    case bitmap(rect: SIMD4<Float>, width: UInt32, height: UInt32, rgba: [UInt8], region: [SIMD4<Float>]?)
    /// A path filled with a repeating tile (pattern and hatch brushes). Items filled with the same brush share its
    /// tile (the same `MetafileTile` instance).
    case pattern(segs: [MetafileSeg], evenOdd: Bool, tile: MetafileTile, region: [SIMD4<Float>]?)
    /// A text string.
    case text(MetafileText)
}

/// A brush tile: RGBA8 rows top-down (transparent where the brush leaves the background), each pixel `cell`
/// picture units, with a tile's top-left corner at `origin`. A class: items filled with the same brush share one
/// instance, so a renderer can key its tile cache by `ObjectIdentifier`.
public final class MetafileTile: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let rgba: [UInt8]
    public let cell: SIMD2<Float>
    public let origin: SIMD2<Float>

    public init(width: UInt32, height: UInt32, rgba: [UInt8], cell: SIMD2<Float>, origin: SIMD2<Float>) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.cell = cell
        self.origin = origin
    }

    public static func == (a: MetafileTile, b: MetafileTile) -> Bool {
        a.width == b.width && a.height == b.height && a.rgba == b.rgba && a.cell == b.cell && a.origin == b.origin
    }
}

public enum MetafileSeg: Equatable, Sendable {
    case move(Float, Float)
    case line(Float, Float)
    case cubic(Float, Float, Float, Float, Float, Float)
    case close
}
