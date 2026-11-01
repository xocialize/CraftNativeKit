// CNMetafile — EMF+ (MS-EMFPLUS): GDI+ drawing records carried in EMF comment records. Port of deckcraft
// crates/metafile/src/emfplus.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Most EMF+ files are *dual*: the same picture is also drawn with plain EMF records, which `EMF` already plays,
// so this reader ignores their EMF+ part. An *EMF+ only* file has nothing else to draw; for those this reader
// plays the records:
// - brushes (solid, hatch, texture, linear and path gradients), pens, paths, images, fonts, string formats and
//   regions, including objects split across several records;
// - rectangles, polygons, lines, ellipses, paths and Béziers;
// - bitmaps (raw pixel formats, and PNG/JPEG/GIF/TIFF/BMP payloads) and strings (DrawString, DrawDriverString
//   with character codes);
// - world and page transforms, save/restore and containers;
// - arcs and pies;
// - clipping to rectangles and convex clip paths and regions (others: their bounding rectangle);
// - nested metafile images, and glyph-index driver strings in the Windows core fonts;
// - cardinal splines (DrawCurve, DrawClosedCurve, FillClosedCurve), FillRegion, and Clear (over the picture
//   frame).
//
// Every drawing record of MS-EMFPLUS §2.3.4 is played. Not drawn: image attributes, glyph indices of other
// fonts, and region combinations other than intersect and union (XOR, exclude and complement keep the left
// area). Deliberately ignored: rendering hints (antialias, text hint, interpolation, pixel offset, compositing;
// the renderer has its own), SetRenderingOrigin (hatch phase), SerializableObject image effects, the
// terminal-server records SetTSGraphics and SetTSClip, and StrokeFillPath (0x4037), which the specification
// lists but gives no layout for and GDI+ doesn't write.
import CNCore
import Darwin

/// GDI+ allows 64 objects; ids are a byte.
private let plusMaxObjects = 64
private let plusMaxStack = 64
/// Points per path or point list read, as the plain EMF reader caps paths.
private let maxPoints = 100_000
/// Gradient stops read from a brush.
private let maxStops = 256
/// Characters per string.
private let plusMaxChars = 32_768
/// Bytes gathered for one object split across records.
private let maxObjectBytes = 64 * 1024 * 1024
/// Nesting depth of region nodes.
private let maxRegionDepth = 32
/// Region nodes and path points parsed together, including nodes in sibling branches.
private let maxRegionWork = maxPoints
/// Metafile images inside metafile images, at most.
private let maxNesting = 3

private let taRight: UInt32 = 2
private let taCenter: UInt32 = 6
private let taBottom: UInt32 = 8
private let taBaseline: UInt32 = 24

/// What a brush paints. Coordinates are in brush space, which `xf` maps to world space.
private enum Fill {
    case solid(MetafileColor)
    case hatch(style: UInt32, fg: MetafileColor, bg: MetafileColor)
    case linear(rect: R4, stops: [(Double, MetafileColor)], wrap: UInt32, xf: Xform)
    case radial(center: P, radius: P, stops: [(Double, MetafileColor)], xf: Xform)
    case texture(img: Rgba, wrap: UInt32, xf: Xform)

    /// One colour standing for the brush (pens and text draw solid).
    var color: MetafileColor {
        switch self {
        case .solid(let c), .hatch(_, let c, _): c
        case .linear(_, let stops, _, _), .radial(_, _, let stops, _): ramp(stops, 0.5)
        case .texture(let img, _, _):
            img.px.count >= 4 ? MetafileColor(img.px[0], img.px[1], img.px[2], img.px[3]) : MetafileColor(0, 0, 0, 255)
        }
    }

    /// The colour at a brush-space point.
    func sample(_ p: P) -> MetafileColor {
        switch self {
        case .solid(let c), .hatch(_, let c, _):
            return c
        case .linear(let rect, let stops, let wrap, _):
            let t = rect[2] == 0 ? 0 : (p.x - rect[0]) / rect[2]
            return ramp(stops, wrapT(t, wrap))
        case .radial(let center, let radius, let stops, _):
            let (dx, dy) = ((p.x - center.x) / radius.x.rustMax(1e-9), (p.y - center.y) / radius.y.rustMax(1e-9))
            return ramp(stops, hypot(dx, dy).rustMin(1))
        case .texture(let img, let wrap, _):
            let (w, h) = (Double(img.w), Double(img.h))
            if w == 0 || h == 0 { return MetafileColor(0, 0, 0, 0) }
            if wrap == 4 && !(p.x >= 0 && p.x < w) || wrap == 4 && !(p.y >= 0 && p.y < h) { return MetafileColor(0, 0, 0, 0) }
            let x = Swift.min(asUsize(remEuclid(p.x, w)), img.w - 1)
            let y = Swift.min(asUsize(remEuclid(p.y, h)), img.h - 1)
            let i = (y * img.w + x) * 4
            guard i + 4 <= img.px.count else { return MetafileColor(0, 0, 0, 0) }
            return MetafileColor(img.px[i], img.px[i + 1], img.px[i + 2], img.px[i + 3])
        }
    }

    var xf: Xform {
        switch self {
        case .linear(_, _, _, let xf), .radial(_, _, _, let xf), .texture(_, _, let xf): xf
        default: identityXform
        }
    }
}

/// Where `t` lands under a wrap mode: tiled, mirrored (flip modes) or clamped.
private func wrapT(_ t: Double, _ wrap: UInt32) -> Double {
    if !t.isFinite { return 0 }
    switch wrap {
    case 1, 3:
        let m = remEuclid(t, 2)
        return m > 1 ? 2 - m : m
    case 4:
        return t.clamped(0, 1)
    default:
        return remEuclid(t, 1)
    }
}

/// The colour at `t` along sorted stops.
private func ramp(_ stops: [(Double, MetafileColor)], _ t: Double) -> MetafileColor {
    guard let first = stops.first, let last = stops.last else { return MetafileColor(0, 0, 0, 0) }
    if t <= first.0 { return first.1 }
    for i in 0 ..< stops.count - 1 {
        let ((a, ca), (b, cb)) = (stops[i], stops[i + 1])
        if t <= b {
            let k = b > a ? (t - a) / (b - a) : 0
            return lerp(ca, cb, k)
        }
    }
    return last.1
}

private func lerp(_ a: MetafileColor, _ b: MetafileColor, _ k: Double) -> MetafileColor {
    var c = MetafileColor(0, 0, 0, 0)
    for i in 0 ..< 4 {
        c[i] = UInt8(rustCast: (Double(a[i]) + (Double(b[i]) - Double(a[i])) * k).rounded().clamped(0, 255))
    }
    return c
}

private struct FontObj {
    var em: Double
    var unit: UInt32
    var style: UInt32
    var family: String
}

private struct Format {
    var flags: UInt32 = 0
    var align: UInt32 = 0
    var lineAlign: UInt32 = 0
}

/// A clip area: a convex polygon (empty clips everything), or nil for infinite.
private typealias Area = [P]?

private enum ImageData {
    case bitmap(Rgba)
    /// A nested WMF or EMF (EMF+) picture.
    case meta(MetafilePicture)
}

private enum PlusObj {
    case brush(Fill)
    case pen(color: MetafileColor, width: Double)
    case path([Op])
    case image(ImageData)
    case font(FontObj)
    case format(Format)
    /// A region's convex area in world units; nil is infinite.
    case region(Area)
}

/// An object arriving in several records: its id, type, total size and the bytes so far.
private struct Partial {
    var id: Int
    var kind: UInt16
    var total: Int
    var data: [UInt8]
}

private struct PlusSaved {
    var id: UInt32
    var world: Xform
    var page: Double
    var clip: Area
}

struct Plus {
    /// "EMF+" as the comment identifier of an EMR_COMMENT holding EMF+ records.
    static let emfPlus: UInt32 = 0x2B46_4D45

    /// An EMF+ header said the file is EMF+ only, so these records are the picture.
    private var active = false
    private var dpi = 96.0
    private var world = identityXform
    private var page = 1.0
    /// Convex device clip polygon; nil is unclipped.
    private var clip: Area = nil
    private var objects = [PlusObj?](repeating: nil, count: plusMaxObjects)
    private var objectBytes = 0
    private var stack: [PlusSaved] = []
    private var partial: Partial?
    /// The picture frame in device units (`[x, y, w, h]`), what Clear paints.
    var frame: R4?
    /// How deep this file sits inside metafile images (deckcraft keeps it in a thread-local).
    private let depth: Int

    init(depth: Int = 0) {
        self.depth = depth
    }

    /// Plays the EMF+ records of one EMR_COMMENT payload (after the identifier).
    mutating func comment(_ cv: inout Canvas, _ data: Bytes) {
        var pos = 0
        while !cv.full {
            guard let tail = data.tail(pos) else { break }
            guard let typ = tail.u16(0), let flags = tail.u16(2), let size32 = tail.u32(4), let dsize32 = tail.u32(8) else { break }
            let (size, dsize) = (Int(size32), Int(dsize32))
            if size < 12 || dsize > size - 12 { break }
            guard let rec = tail.slice(12, dsize) else { break }
            _ = record(&cv, typ, flags, rec)
            let (next, overflow) = pos.addingReportingOverflow(size)
            if overflow { break }
            pos = next
        }
    }

    /// World units to device pixels before the canvas's own mapping.
    private var xf: Xform { mul(world, [page, 0, 0, page, 0, 0]) }

    private var painter: Painter { Painter(xf: xf, clip: clip) }

    private mutating func record(_ cv: inout Canvas, _ typ: UInt16, _ flags: UInt16, _ r: Bytes) -> Void? {
        if typ == 0x4001 {
            // Header: dual files also draw with EMF records, which win.
            active = flags & 1 == 0
            if let d = r.u32(8).map(Double.init), d > 0, d < 100_000 { dpi = d }
            return ()
        }
        if !active { return nil }
        let compressed = flags & 0x4000 != 0
        let id = Int(flags & 0xFF)
        switch typ {
        case 0x4008:
            return object(flags, r)
        case 0x400A:
            guard let v = r.u32(0), let fill = brushOf(flags, v), let n = r.u32(4),
                  let rcs = rects(r, 8, Int(n), compressed) else { return nil }
            let p = painter
            for rc in rcs {
                if cv.full { break }
                p.fill(&cv, rectOps(rc), fill)
            }
            return ()
        case 0x400B:
            guard let pen = pen(id), let n = r.u32(0), let rcs = rects(r, 4, Int(n), compressed) else { return nil }
            let p = painter
            for rc in rcs {
                if cv.full { break }
                p.stroke(&cv, rectOps(rc), pen)
            }
            return ()
        case 0x400C:
            guard let v = r.u32(0), let fill = brushOf(flags, v), let n = r.u32(4),
                  let pts = points(r, 8, Int(n), compressed) else { return nil }
            painter.fill(&cv, polyOps(pts, close: true), fill)
            return ()
        case 0x400D:
            guard let pen = pen(id), let n = r.u32(0), let pts = points(r, 4, Int(n), compressed) else { return nil }
            painter.stroke(&cv, polyOps(pts, close: flags & 0x2000 != 0), pen)
            return ()
        case 0x400E:
            guard let v = r.u32(0), let fill = brushOf(flags, v), let rect = rects(r, 4, 1, compressed)?.first else { return nil }
            painter.fill(&cv, ellipseOps(rect), fill)
            return ()
        case 0x400F:
            guard let pen = pen(id), let rect = rects(r, 0, 1, compressed)?.first else { return nil }
            painter.stroke(&cv, ellipseOps(rect), pen)
            return ()
        case 0x4014:
            guard let v = r.u32(0), let fill = brushOf(flags, v), let ops = path(id) else { return nil }
            painter.fill(&cv, ops, fill)
            return ()
        case 0x4015:
            guard let ops = path(id), let pid = r.u32(0), let pen = pen(Int(pid)) else { return nil }
            painter.stroke(&cv, ops, pen)
            return ()
        case 0x4019:
            guard let pen = pen(id), let n = r.u32(0), let pts = points(r, 4, Int(n), compressed), let first = pts.first else {
                return nil
            }
            var ops: [Op] = [.m(first)]
            let rest = Array(pts.dropFirst())
            for k in stride(from: 0, to: rest.count - 2, by: 3) { ops.append(.c(rest[k], rest[k + 1], rest[k + 2])) }
            painter.stroke(&cv, ops, pen)
            return ()
        // Cardinal splines: FillClosedCurve, DrawClosedCurve, DrawCurve.
        case 0x4016:
            guard let v = r.u32(0), let fill = brushOf(flags, v), let tf = r.f32(4), let tension = finite(tf), let n = r.u32(8),
                  let pts = points(r, 12, Int(n), compressed) else { return nil }
            painter.fill(&cv, curveOps(pts, tension, closed: true, 0, Int.max), fill)
            return ()
        case 0x4017:
            guard let pen = pen(id), let tf = r.f32(0), let tension = finite(tf), let n = r.u32(4),
                  let pts = points(r, 8, Int(n), compressed) else { return nil }
            painter.stroke(&cv, curveOps(pts, tension, closed: true, 0, Int.max), pen)
            return ()
        case 0x4018:
            guard let pen = pen(id), let tf = r.f32(0), let tension = finite(tf), let offset = r.u32(4), let segments = r.u32(8),
                  let n = r.u32(12), let pts = points(r, 16, Int(n), compressed) else { return nil }
            painter.stroke(&cv, curveOps(pts, tension, closed: false, Int(offset), Int(segments)), pen)
            return ()
        // Clear: the whole picture in one colour, whatever the clip (a transparent clear leaves nothing to draw).
        case 0x4009:
            guard let v = r.u32(0), let f = frame else { return nil }
            let c = argb(v)
            let (x, y, w, h) = (f[0], f[1], f[2], f[3])
            if c[3] == 0 || !(w > 0 && h > 0) { return () }
            guard let toDevice = invert(mul(cv.world, cv.deviceAffine)) else { return nil }
            Painter(xf: toDevice, clip: nil).fill(&cv, rectOps(R4(x, y, x + w, y + h)), .solid(c))
            return ()
        // FillRegion: the region's area (as the clip reads it).
        case 0x4013:
            guard let v = r.u32(0), let fill = brushOf(flags, v) else { return nil }
            guard case .region(let a)?? = objects.at(id), let area = a, area.count >= 3 else { return nil }
            painter.fill(&cv, polyOps(area, close: true), fill)
            return ()
        case 0x401A:
            guard let img = image(id), let dst = rects(r, 24, 1, compressed)?.first else { return nil }
            return drawImage(&cv, img, r, R4(dst[0], dst[1], dst[2] - dst[0], dst[3] - dst[1]))
        case 0x401B:
            guard let img = image(id), let pts = points(r, 28, 3, compressed), pts.count >= 3 else { return nil }
            let (p0, p1, p2) = (pts[0], pts[1], pts[2])
            // The destination parallelogram's top-left, top-right and bottom-left corners; a sheared or rotated
            // one is drawn into its bounding rectangle's axes.
            let dst = R4(p0.x, p0.y, p1.x - p0.x + (p2.x - p0.x), p2.y - p0.y + (p1.y - p0.y))
            return drawImage(&cv, img, r, dst)
        case 0x401C:
            return drawString(&cv, flags, r)
        case 0x4036:
            return drawDriverString(&cv, flags, r)
        case 0x4025, 0x4028:
            guard let i = r.u32(0) else { return nil }
            push(i)
            return ()
        case 0x4027:
            guard let i = r.u32(24) else { return nil }
            push(i)
            return ()
        case 0x4026, 0x4029:
            guard let i = r.u32(0) else { return nil }
            pop(i)
            return ()
        case 0x402A:
            guard let m = matrix(r, 0) else { return nil }
            world = m
            return ()
        case 0x402B:
            world = identityXform
            return ()
        case 0x402C:
            guard let m = matrix(r, 0) else { return nil }
            return apply(m, flags)
        case 0x402D:
            guard let dx = r.f32(0), let dy = r.f32(4) else { return nil }
            return apply([1, 0, 0, 1, Double(dx), Double(dy)], flags)
        case 0x402E:
            guard let sx = r.f32(0), let sy = r.f32(4) else { return nil }
            return apply([Double(sx), 0, 0, Double(sy), 0, 0], flags)
        case 0x402F:
            guard let deg = r.f32(0) else { return nil }
            let (s, c) = sinCos(Double(deg).toRadians)
            return apply([c, s, -s, c, 0, 0], flags)
        case 0x4030:
            guard let v = r.f32(0) else { return nil }
            let pg = Double(v) * unitPx(UInt32(flags & 0xFF), dpi)
            if pg.isFinite && pg > 0 && pg < 1.0e6 { page = pg }
            return ()
        case 0x4031:
            clip = nil
            return ()
        case 0x4032:
            guard let f = floats(r, 0, 4) else { return nil }
            let (x, y, w, h) = (f[0], f[1], f[2], f[3])
            let area = mapArea(ClipRect.rectPoly(R4(x, y, x + w, y + h)), mul(xf, cv.deviceAffine))
            return combine(flags, area)
        case 0x4033:
            guard let ops = path(id) else { return nil }
            return combine(flags, mapArea(areaOfOps(ops), mul(xf, cv.deviceAffine)))
        case 0x4034:
            guard case .region(let reg)?? = objects.at(id) else { return nil }
            return combine(flags, mapArea(reg, mul(xf, cv.deviceAffine)))
        case 0x4035:
            guard let f = floats(r, 0, 2) else { return nil }
            let (dx, dy) = (f[0], f[1])
            let a = mul(xf, cv.deviceAffine)
            let (ox, oy) = (dx * a[0] + dy * a[2], dx * a[1] + dy * a[3])
            if let c = clip { clip = c.map { P($0.x + ox, $0.y + oy) } }
            return ()
        case 0x4010:
            guard let v = r.u32(0), let fill = brushOf(flags, v), let f = floats(r, 4, 2),
                  let rect = rects(r, 12, 1, compressed)?.first else { return nil }
            painter.fill(&cv, arcOps(rect, f[0], f[1], pie: true), fill)
            return ()
        case 0x4011, 0x4012:
            guard let pen = pen(id), let f = floats(r, 0, 2), let rect = rects(r, 8, 1, compressed)?.first else { return nil }
            painter.stroke(&cv, arcOps(rect, f[0], f[1], pie: typ == 0x4011), pen)
            return ()
        default:
            return nil
        }
    }

    /// Without the `A` flag a transform is applied before the world transform (prepended).
    private mutating func apply(_ m: Xform, _ flags: UInt16) -> Void? {
        world = flags & 0x2000 != 0 ? mul(world, m) : mul(m, world)
        return ()
    }

    private mutating func push(_ id: UInt32) {
        if stack.count < plusMaxStack { stack.append(PlusSaved(id: id, world: world, page: page, clip: clip)) }
    }

    private mutating func pop(_ id: UInt32) {
        guard let i = stack.lastIndex(where: { $0.id == id }) else { return }
        let s = stack[i]
        (world, page, clip) = (s.world, s.page, s.clip)
        stack.removeSubrange(i...)
    }

    /// Combines a new clip area with the current one under the record's combine mode: replace, intersect and union
    /// (as the rectangle around both). XOR, exclude and complement leave the clip as it was.
    private mutating func combine(_ flags: UInt16, _ new: Area) -> Void? {
        switch (flags >> 8) & 0xF {
        case 0: clip = new
        case 1: clip = areaIntersect(clip, new)
        case 2: clip = areaUnion(clip, new)
        default: break
        }
        return ()
    }

    private mutating func object(_ flags: UInt16, _ r: Bytes) -> Void? {
        let id = Int(flags & 0xFF)
        let kind = (flags >> 8) & 0x7F
        if flags & 0x8000 != 0 {
            // A continued object: the total size, then this record's share of the bytes.
            guard let t = r.u32(0), let chunk = r.tail(4) else { return nil }
            let total = Swift.min(Int(t), maxObjectBytes)
            var p = partial.flatMap { $0.id == id && $0.kind == kind && $0.total == total ? $0 : nil }
                ?? Partial(id: id, kind: kind, total: total, data: [])
            partial = nil
            let room = Swift.max(p.total - p.data.count, 0)
            p.data += chunk.view.prefix(room)
            if p.data.count >= p.total {
                store(p.id, parseObject(p.kind, Bytes(p.data), depth))
            } else {
                partial = p
            }
            return ()
        }
        // The last piece of a continued object comes without the continue flag.
        let pending = partial
        partial = nil
        if var p = pending, p.id == id, p.kind == kind {
            let room = Swift.max(p.total - p.data.count, 0)
            p.data += r.view.prefix(room)
            store(id, parseObject(kind, Bytes(p.data), depth))
            return ()
        }
        store(id, parseObject(kind, r, depth))
        return ()
    }

    private mutating func store(_ id: Int, _ obj: PlusObj?) {
        guard objects.indices.contains(id) else { return }
        if let old = objects[id] {
            objectBytes = Swift.max(objectBytes - Self.objCost(old), 0)
            objects[id] = nil
        }
        if let new = obj {
            let cost = Self.objCost(new)
            let (sum, overflow) = objectBytes.addingReportingOverflow(cost)
            if !overflow && sum <= Metafile.maxBytes {
                objectBytes = sum
                objects[id] = new
            }
        }
    }

    private static func objCost(_ obj: PlusObj) -> Int {
        switch obj {
        case .image(.bitmap(let rgba)): rgba.px.count
        case .image(.meta(let pic)): pic.items.count.multipliedReportingOverflow(by: 128).overflow ? .max : pic.items.count * 128
        case .brush(.texture(let img, _, _)): img.px.count
        case .path(let ops): ops.count * opSize
        default: 0
        }
    }

    private func path(_ id: Int) -> [Op]? {
        guard case .path(let ops)?? = objects.at(id) else { return nil }
        return ops
    }

    private func pen(_ id: Int) -> (MetafileColor, Double)? {
        guard case .pen(let color, let width)?? = objects.at(id) else { return nil }
        return (color, width)
    }

    private func image(_ id: Int) -> ImageData? {
        guard case .image(let img)?? = objects.at(id) else { return nil }
        return img
    }

    /// The brush of a fill record: an ARGB value with the `S` flag, else a brush object.
    private func brushOf(_ flags: UInt16, _ v: UInt32) -> Fill? {
        if flags & 0x8000 != 0 { return .solid(argb(v)) }
        guard case .brush(let f)?? = objects.at(Int(v)) else { return nil }
        return f
    }

    /// DrawImage and DrawImagePoints: the source rectangle (pixels) cut from the image, drawn into world rectangle
    /// `dst` = `[x, y, w, h]`.
    private func drawImage(_ cv: inout Canvas, _ img: ImageData, _ r: Bytes, _ dst: R4) -> Void? {
        let bmp: Rgba
        switch img {
        case .bitmap(let b): bmp = b
        case .meta(let pic):
            painter.picture(&cv, dst, pic)
            return ()
        }
        guard let f = floats(r, 8, 4), let unit = r.u32(4) else { return nil }
        let src: [Int64] = unit == 2 ? f.map { Int64(rustCast: $0.rounded().clamped(-1.0e9, 1.0e9)) } : [0, 0, 0, 0]
        guard let (part, d) = DIB.clipBlit(bmp, src, dst) else { return nil }
        painter.image(&cv, d, part)
        return ()
    }

    private func font(_ id: Int) -> FontObj? {
        guard case .font(let f)?? = objects.at(id) else { return nil }
        return f
    }

    /// The font as a LOGFONT whose height is in world units.
    private func logFont(_ f: FontObj) -> LogFont {
        let em = f.unit == 0 ? f.em : f.em * unitPx(f.unit, dpi) / page
        let font = MetafileFont(
            family: f.family,
            height: -Float(em.clamped(0, 1.0e6)),
            weight: f.style & 1 != 0 ? 700 : 400,
            italic: f.style & 2 != 0,
            underline: f.style & 4 != 0,
            strike: f.style & 8 != 0
        )
        return LogFont(font: font, escapement: 0)
    }

    /// DrawString: lines of text laid out in a rectangle by the string format's alignments.
    private func drawString(_ cv: inout Canvas, _ flags: UInt16, _ r: Bytes) -> Void? {
        guard let font = font(Int(flags & 0xFF)), let v = r.u32(0), let brush = brushOf(flags, v), let fid = r.u32(4) else { return nil }
        let color = brush.color
        var fmt = Format()
        if case .format(let f)?? = objects.at(Int(fid)) { fmt = f }
        guard let l = r.u32(8), let rect = floats(r, 12, 4) else { return nil }
        let len = Swift.min(Int(l), plusMaxChars)
        let (x, y, w, h) = (rect[0], rect[1], rect[2], rect[3])
        var units: [UInt16] = []
        units.reserveCapacity(len)
        for i in 0 ..< len {
            guard let u = r.u16(28 + i * 2) else { return nil }
            units.append(u)
        }
        let lf = logFont(font)
        let em = Double(-lf.font.height)
        let wrap = w > 0 && fmt.flags & 0x1000 == 0
        let lines: [[UInt16]] = units.split(separator: 0x0A, omittingEmptySubsequences: false).flatMap { piece -> [[UInt16]] in
            let line = piece.filter { $0 != 0x0D }
            return wrap ? wrapLine(line, w, em) : [line]
        }
        let lineH = em * 1.2
        let (ax, taH): (Double, UInt32) = switch fmt.align {
        case 1: (x + w / 2, taCenter)
        case 2: (x + w, taRight)
        default: (x, 0)
        }
        let block = lineH * Double(lines.count)
        let top = switch fmt.lineAlign {
        case 1: y + (h - block) / 2
        case 2: y + h - block
        default: y
        }
        let clipRect: R4? = w > 0 && h > 0 && fmt.flags & 0x4000 == 0 ? R4(x, y, x + w, y + h) : nil
        let p = painter
        for (i, line) in lines.enumerated() {
            if line.isEmpty { continue }
            let (text, dx) = decodeUTF16(line, [])
            var at = P(ax, top + lineH * Double(i))
            var ta = taH
            if fmt.lineAlign == 2 && lines.count == 1 { (at, ta) = (P(ax, y + h), taH | taBottom) }
            p.text(&cv, at, text, dx, TextStyle(color: color, font: lf, align: ta, clip: clipRect), identityXform)
        }
        return ()
    }

    /// DrawDriverString with character codes (CmapLookup): positioned glyphs on a baseline.
    private func drawDriverString(_ cv: inout Canvas, _ flags: UInt16, _ r: Bytes) -> Void? {
        guard let font = font(Int(flags & 0xFF)), let v = r.u32(0), let brush = brushOf(flags, v), let opts = r.u32(4),
              let count = r.u32(12) else { return nil }
        let color = brush.color
        let n = Swift.min(Int(count), plusMaxChars)
        var units: [UInt16] = []
        units.reserveCapacity(n)
        for i in 0 ..< n {
            guard let u = r.u16(16 + i * 2) else { return nil }
            units.append(u)
        }
        if opts & 1 == 0 {
            // Glyph indices into the font. The crate knows no fonts, but the classic Windows core fonts keep the
            // standard Macintosh glyph order for ASCII, so those map back.
            guard let mapped = glyphsToChars(font.family, units) else { return nil }
            units = mapped
        }
        guard let pos = points(r, 16 + n * 2, n, false), let hasMatrix = r.u32(8) else { return nil }
        var m = identityXform
        if hasMatrix != 0 {
            guard let mm = matrix(r, 16 + n * 10) else { return nil }
            m = mm
        }
        let lf = logFont(font)
        guard let first = pos.first else { return nil }
        var dx: [Float] = []
        if opts & 4 == 0 {
            dx = (0 ..< Swift.max(pos.count - 1, 0)).map { Float(pos[$0 + 1].x - pos[$0].x) }
            dx.append(dx.last ?? -lf.font.height * 0.5)
        }
        let (text, adv) = decodeUTF16(units, dx)
        painter.text(&cv, first, text, adv, TextStyle(color: color, font: lf, align: taBaseline, clip: nil), m)
        return ()
    }
}

/// Page unit to device pixels: world, display and pixel are 1; point, inch, document, mm.
private func unitPx(_ unit: UInt32, _ dpi: Double) -> Double {
    switch unit {
    case 3: dpi / 72
    case 4: dpi
    case 5: dpi / 300
    case 6: dpi / 25.4
    default: 1
    }
}

private struct TextStyle {
    var color: MetafileColor
    var font: LogFont
    var align: UInt32
    /// World clip rectangle `[l, t, r, b]`.
    var clip: R4?
}

/// Draws through the canvas with EMF+'s transform, clip and its own pen or brush, then puts the canvas's GDI
/// state back.
private struct Painter {
    var xf: Xform
    var clip: Area

    private func begin(_ cv: inout Canvas, _ pre: Xform) {
        let world = cv.world
        cv.saveDC()
        cv.modifyWorld(mul(mul(pre, xf), world), 4)
        cv.setClip(clip)
    }

    private func end(_ cv: inout Canvas) {
        cv.restoreDC(-1)
        cv.setClip(nil)
    }

    private static func noPen(_ cv: inout Canvas) {
        cv.setPen(Pen(style: psNull, width: 0, color: MetafileColor(0, 0, 0, 0)))
    }

    func fill(_ cv: inout Canvas, _ ops: [Op], _ fill: Fill) {
        begin(&cv, identityXform)
        Self.noPen(&cv)
        switch fill {
        case .solid(let c):
            cv.setBrush(Brush(bsSolid, c))
            cv.shape(ops, fill: true, stroke: false)
        case .hatch(let style, let fg, let bg):
            if let px = hatchTile(style, fg, bg) {
                cv.tileShape(ops, RawTile(w: 8, h: 8, px: px, cell: cv.patternPx))
            } else {
                // GDI+ has many more hatch styles than GDI: those fill with the blend of both colours.
                cv.setBrush(Brush(bsSolid, lerp(fg, bg, 0.5)))
                cv.shape(ops, fill: true, stroke: false)
            }
        default:
            // Device point to brush space: invert brush space → world → device.
            if let inv = invert(mul(fill.xf, cv.deviceAffine)) {
                cv.shadeShape(ops) { fill.sample(applyXform(inv, $0)) }
            }
        }
        end(&cv)
    }

    func stroke(_ cv: inout Canvas, _ ops: [Op], _ pen: (MetafileColor, Double)) {
        begin(&cv, identityXform)
        cv.setPen(Pen(style: 0, width: pen.1, color: pen.0))
        cv.setBrush(Brush(bsNull, MetafileColor(0, 0, 0, 0)))
        cv.shape(ops, fill: false, stroke: true)
        end(&cv)
    }

    func image(_ cv: inout Canvas, _ dst: R4, _ img: Rgba) {
        begin(&cv, identityXform)
        cv.bitmap(dst, img)
        end(&cv)
    }

    /// A nested metafile's picture stretched into world rectangle `dst` = `[x, y, w, h]`.
    func picture(_ cv: inout Canvas, _ dst: R4, _ pic: MetafilePicture) {
        begin(&cv, identityXform)
        let (x, y, w, h) = (dst[0], dst[1], dst[2], dst[3])
        let (sx, sy) = (w / Double(pic.width), h / Double(pic.height))
        let m = mul([sx, 0, 0, sy, x, y], cv.deviceAffine)
        let scale = Swift.abs(m[0] * m[3] - m[1] * m[2]).squareRoot()
        func pt(_ a: Float, _ b: Float) -> P { applyXform(m, P(Double(a), Double(b))) }
        func ops(_ segs: [MetafileSeg]) -> [Op] {
            segs.map {
                switch $0 {
                case .move(let a, let b): .m(pt(a, b))
                case .line(let a, let b): .l(pt(a, b))
                case .cubic(let a, let b, let c, let d, let e, let f): .c(pt(a, b), pt(c, d), pt(e, f))
                case .close: .z
                }
            }
        }
        // The nested picture's own clip regions are not carried over: each item takes the canvas's current clip.
        for item in pic.items {
            if cv.full { break }
            let raw: Raw
            switch item {
            case .path(let segs, let fill, let stroke, let evenOdd, _):
                raw = .path(ops: ops(segs), fill: fill, stroke: stroke.map { ($0.color, Double($0.width) * scale) }, evenOdd: evenOdd, region: nil)
            case .pattern(let segs, let evenOdd, let tile, _):
                let t = RawTile(w: Int(tile.width), h: Int(tile.height), px: tile.rgba, cell: Double(tile.cell[0]) * scale)
                raw = .pattern(ops: ops(segs), evenOdd: evenOdd, tile: t, region: nil)
            case .bitmap(let rect, let width, let height, let rgba, _):
                let (a, b) = (pt(rect[0], rect[1]), pt(rect[0] + rect[2], rect[1] + rect[3]))
                var img = Rgba(w: Int(width), h: Int(height), bottomUp: false, px: rgba)
                DIB.flip(&img, horizontal: a.x > b.x, vertical: a.y > b.y)
                raw = .bitmap(rect: R4(a.x.rustMin(b.x), a.y.rustMin(b.y), Swift.abs(b.x - a.x), Swift.abs(b.y - a.y)), img: img, region: nil)
            case .text(var t):
                t.transform = mul(t.transform, m)
                if let c = t.clip {
                    let (p, q) = (pt(c[0], c[1]), pt(c[2], c[3]))
                    t.clip = SIMD4<Float>(Float(p.x.rustMin(q.x)), Float(p.y.rustMin(q.y)), Float(p.x.rustMax(q.x)), Float(p.y.rustMax(q.y)))
                }
                raw = .text(t, region: nil)
            }
            cv.pushDevice(raw)
        }
        end(&cv)
    }

    func text(_ cv: inout Canvas, _ at: P, _ text: String, _ dx: [Float], _ style: TextStyle, _ pre: Xform) {
        begin(&cv, pre)
        cv.setTextStyle(style.color, style.font, style.align)
        var (opts, rect): (UInt32, R4?) = (0, nil)
        if let c = style.clip { (opts, rect) = (etoClipped, c) }
        cv.text(at, text, dx, opts, rect)
        end(&cv)
    }
}

private func applyXform(_ m: Xform, _ p: P) -> P {
    P(p.x * m[0] + p.y * m[2] + m[4], p.x * m[1] + p.y * m[3] + m[5])
}

private func invert(_ m: Xform) -> Xform? {
    let det = m[0] * m[3] - m[1] * m[2]
    if !det.isFinite || Swift.abs(det) < 1e-12 { return nil }
    let (a, b, c, d) = (m[3] / det, -m[1] / det, -m[2] / det, m[0] / det)
    return [a, b, c, d, -(m[4] * a + m[5] * c), -(m[4] * b + m[5] * d)]
}

/// ARGB (0xAARRGGBB) to RGBA.
private func argb(_ v: UInt32) -> MetafileColor {
    MetafileColor(UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 24))
}

/// `n` f32 values at `off` as f64, or nil when one is missing or not finite.
private func floats(_ r: Bytes, _ off: Int, _ n: Int) -> [Double]? {
    var v: [Double] = []
    v.reserveCapacity(n)
    for i in 0 ..< n {
        guard let x = r.f32(off + i * 4) else { return nil }
        v.append(Double(x))
    }
    return v.allSatisfy(\.isFinite) ? v : nil
}

private func matrix(_ r: Bytes, _ off: Int) -> Xform? {
    floats(r, off, 6)
}

private func parseObject(_ kind: UInt16, _ r: Bytes, _ depth: Int) -> PlusObj? {
    switch kind {
    case 1: return brush(r, 0, depth).map { .brush($0) }
    case 2: return pen(r, depth)
    case 3: return path(r).map { .path($0) }
    case 4: return region(r)
    case 5: return image(r, depth).map { .image($0) }
    case 6: return font(r)
    case 7:
        guard let flags = r.u32(4), let align = r.u32(12), let lineAlign = r.u32(16) else { return nil }
        return .format(Format(flags: flags, align: align, lineAlign: lineAlign))
    default: return nil
    }
}

/// A brush object at `off`: version, type, then the type's data.
private func brush(_ r: Bytes, _ off: Int, _ depth: Int) -> Fill? {
    guard let d = r.tail(off + 8), let kind = r.u32(off + 4) else { return nil }
    switch kind {
    case 0:
        return d.u32(0).map { .solid(argb($0)) }
    case 1:
        guard let style = d.u32(0), let fg = d.u32(4), let bg = d.u32(8) else { return nil }
        return .hatch(style: style, fg: argb(fg), bg: argb(bg))
    case 2:
        guard let bflags = d.u32(0), let wrap = d.u32(4) else { return nil }
        var (xf, off) = (identityXform, 8)
        if bflags & 0x2 != 0 {
            guard let m = matrix(d, 8) else { return nil }
            (xf, off) = (m, 32)
        }
        guard let t = d.tail(off), case .bitmap(let img)? = image(t, depth) else { return nil }
        return .texture(img: img, wrap: wrap, xf: xf)
    case 3:
        return pathGradient(d)
    case 4:
        return linearGradient(d)
    default:
        return nil
    }
}

/// `n` f32 values at `off` widened to f64, or nil when one is missing.
private func f64s(_ d: Bytes, _ off: Int, _ n: Int) -> [Double]? {
    var v: [Double] = []
    v.reserveCapacity(n)
    for i in 0 ..< n {
        guard let x = d.f32(off + i * 4) else { return nil }
        v.append(Double(x))
    }
    return v
}

private func linearGradient(_ d: Bytes) -> Fill? {
    guard let bflags = d.u32(0), let wrap = d.u32(4), let rect = floats(d, 8, 4), let a = d.u32(24), let b = d.u32(28) else {
        return nil
    }
    let (c0, c1) = (argb(a), argb(b))
    var off = 40
    var xf = identityXform
    if bflags & 0x2 != 0 {
        guard let m = matrix(d, off) else { return nil }
        xf = m
        off += 24
    }
    var stops: [(Double, MetafileColor)] = [(0, c0), (1, c1)]
    if bflags & 0x4 != 0 {
        // Preset colours: positions, then one colour each.
        guard let count = d.u32(off) else { return nil }
        let n = Swift.min(Int(count), maxStops)
        guard let pos = f64s(d, off + 4, n) else { return nil }
        var cols: [MetafileColor] = []
        for i in 0 ..< n {
            guard let c = d.u32(off + 4 + n * 4 + i * 4) else { return nil }
            cols.append(argb(c))
        }
        stops = Array(zip(pos, cols))
    } else if bflags & 0x8 != 0 {
        // Blend factors: positions, then how far from the start colour to the end colour.
        guard let count = d.u32(off) else { return nil }
        let n = Swift.min(Int(count), maxStops)
        guard let pos = f64s(d, off + 4, n), let fac = f64s(d, off + 4 + n * 4, n) else { return nil }
        stops = zip(pos, fac).map { ($0, lerp(c0, c1, $1.clamped(0, 1))) }
    }
    stops = stops.filter { $0.0.isFinite }
    // A stable sort by Rust's `total_cmp` (−0 before +0).
    stops = stops.enumerated().sorted { a, b in
        let (x, y) = (a.element.0, b.element.0)
        if x != y { return x < y }
        if x.sign != y.sign { return x.sign == .minus }
        return a.offset < b.offset
    }.map(\.element)
    return stops.isEmpty ? nil : .linear(rect: R4(rect[0], rect[1], rect[2], rect[3]), stops: stops, wrap: wrap, xf: xf)
}

/// A path gradient: from the centre colour to the (first) surrounding colour at the boundary, taken as the ellipse
/// in the boundary's bounding rectangle.
private func pathGradient(_ d: Bytes) -> Fill? {
    guard let bflags = d.u32(0), let cc = d.u32(8), let c = floats(d, 12, 2), let nc32 = d.u32(20) else { return nil }
    let centerC = argb(cc)
    let nc = Swift.min(Int(nc32), maxStops)
    var surround = centerC
    if nc > 0 {
        guard let s = d.u32(24) else { return nil }
        surround = argb(s)
    }
    var off = 24 + nc * 4
    let bbox: R4
    if bflags & 0x1 != 0 {
        guard let size = d.u32(off), let t = d.tail(off + 4), let ops = path(t), let b = ClipRect.opsBBox(ops) else { return nil }
        off += 4 + Int(size)
        bbox = b
    } else {
        guard let n32 = d.u32(off) else { return nil }
        let n = Int(n32)
        guard let pts = points(d, off + 4, n, false) else { return nil }
        off += 4 + 8 * Swift.min(n, maxPoints)
        guard let b = ClipRect.opsBBox(polyOps(pts, close: true)) else { return nil }
        bbox = b
    }
    var xf = identityXform
    if bflags & 0x2 != 0 {
        guard let m = matrix(d, off) else { return nil }
        xf = m
    }
    let radius = P((bbox[2] - bbox[0]) / 2, (bbox[3] - bbox[1]) / 2)
    return .radial(center: P(c[0], c[1]), radius: radius, stops: [(0, centerC), (1, surround)], xf: xf)
}

/// A pen object: version, type, then pen data (flags, unit, width, optional fields), then a brush.
private func pen(_ r: Bytes, _ depth: Int) -> PlusObj? {
    guard let pflags = r.u32(8), let wf = r.f32(16) else { return nil }
    let width = Double(wf)
    var off = 20
    for (bit, len) in [(0x1, 24), (0x2, 4), (0x4, 4), (0x8, 4), (0x10, 4), (0x20, 4), (0x40, 4), (0x80, 4)] as [(UInt32, Int)] {
        if pflags & bit != 0 { off += len }
    }
    for bit: UInt32 in [0x100, 0x200, 0x400] where pflags & bit != 0 {
        if bit == 0x200 {
            off += 4
        } else {
            guard let n = r.u32(off) else { return nil }
            off += 4 + 4 * Swift.min(Int(n), maxPoints)
        }
    }
    for bit: UInt32 in [0x800, 0x1000] where pflags & bit != 0 {
        guard let n = r.u32(off) else { return nil }
        off += 4 + Swift.min(Int(n), 1 << 20)
    }
    guard let color = brush(r, off, depth)?.color else { return nil }
    return .pen(color: color, width: width.isFinite ? width.clamped(0, 1.0e5) : 0)
}

/// A path object: points, then one type byte per point (start, line, Bézier; 0x80 closes).
private func path(_ r: Bytes) -> [Op]? {
    guard let count = r.u32(4), let pflags = r.u32(8) else { return nil }
    let n = Swift.min(Int(count), maxPoints)
    if pflags & 0x1800 != 0 {
        // Relative (0x0800) and run-length encoded (0x1000) points: not read yet.
        return nil
    }
    let compressed = pflags & 0x4000 != 0
    guard let pts = points(r, 12, n, compressed) else { return nil }
    let toff = 12 + n * (compressed ? 4 : 8)
    guard let typesBytes = r.slice(toff, n) else { return nil }
    let types = typesBytes.array
    var ops: [Op] = []
    ops.reserveCapacity(n + 4)
    var i = 0
    while i < n {
        let (t, p) = (types[i], pts[i])
        if t & 0x07 == 3 && i + 2 < n {
            ops.append(.c(p, pts[i + 1], pts[i + 2]))
            if types[i + 2] & 0x80 != 0 { ops.append(.z) }
            i += 3
            continue
        }
        ops.append(t & 0x07 == 0 ? .m(p) : .l(p))
        if t & 0x80 != 0 { ops.append(.z) }
        i += 1
    }
    return ops
}

/// A region object as a convex area in world units (non-convex parts become their bounding rectangle).
private func region(_ r: Bytes) -> PlusObj? {
    var work = 0
    return regionNode(r, 8, 0, &work).map { .region($0.0) }
}

/// One region node at `off`: its area and its length in bytes. `work` counts the nodes and path points
/// parsed so far, sibling branches included.
private func regionNode(_ r: Bytes, _ off: Int, _ depth: Int, _ work: inout Int) -> (Area, Int)? {
    work += 1
    if depth > maxRegionDepth || work > maxRegionWork { return nil }
    guard let kind = r.u32(off) else { return nil }
    switch kind {
    case 0x1000_0000:
        guard let f = floats(r, off + 4, 4) else { return nil }
        let (x, y, w, h) = (f[0], f[1], f[2], f[3])
        return (ClipRect.rectPoly(R4(x.rustMin(x + w), y.rustMin(y + h), x.rustMax(x + w), y.rustMax(y + h))), 20)
    case 0x1000_0001:
        // The path is read from its own bytes only, so it can't take points from the node after it.
        guard let size = r.u32(off + 4), size >= 12, let data = r.slice(off + 8, Int(size)), let n = data.u32(4) else { return nil }
        work += Swift.min(Int(n), maxPoints)
        guard work <= maxRegionWork, let ops = path(data) else { return nil }
        return (areaOfOps(ops), 8 + Int(size))
    case 0x1000_0002:
        return ([], 4)
    case 0x1000_0003:
        return (nil, 4)
    case 0 ... 5:
        guard let (a, la) = regionNode(r, off + 4, depth + 1, &work), let (b, lb) = regionNode(r, off + 4 + la, depth + 1, &work) else { return nil }
        let out: Area = switch kind {
        case 0: b
        case 1: areaIntersect(a, b)
        case 2: areaUnion(a, b)
        // XOR, exclude, complement: the left area bounds the result closely enough.
        default: a
        }
        return (out, 4 + la + lb)
    default:
        return nil
    }
}

/// The area a path encloses: its outline when that is one convex figure, else the rectangle around it.
private func areaOfOps(_ ops: [Op]) -> [P] {
    let subs = ClipRect.flatten(ops)
    if subs.count == 1, let c = ClipRect.convex(subs[0].pts) { return c }
    return ClipRect.opsBBox(ops).map(ClipRect.rectPoly) ?? []
}

private func areaIntersect(_ a: Area, _ b: Area) -> Area {
    guard let a else { return b }
    guard let b else { return a }
    if a.count >= 3 && b.count >= 3 { return ClipRect.convex(ClipRect.clipPolygon(a, b)) ?? [] }
    return []
}

private func areaUnion(_ a: Area, _ b: Area) -> Area {
    guard let a, let b else { return nil }
    if a.count < 3 { return b }
    if b.count < 3 { return a }
    return ClipRect.ptsBBox(a + b).map(ClipRect.rectPoly) ?? []
}

/// An area through an affine map (which keeps it convex; the orientation is put right again).
private func mapArea(_ a: Area, _ m: Xform) -> Area {
    a.map { pts in
        let mapped = pts.map { applyXform(m, $0) }
        return mapped.count < 3 ? [] : ClipRect.convex(mapped) ?? []
    }
}

/// An elliptical arc in `rect` from `start` sweeping `sweep` degrees (clockwise on screen), as cubics; a pie adds
/// the lines to and from the centre.
private func arcOps(_ rect: R4, _ start: Double, _ sweep: Double, pie: Bool) -> [Op] {
    let (l, t, r, b) = (rect[0], rect[1], rect[2], rect[3])
    let (cx, cy, rx, ry) = ((l + r) / 2, (t + b) / 2, (r - l) / 2, (b - t) / 2)
    let sweep = sweep.clamped(-360, 360)
    // GDI+ angles are along rays from the centre; turn them into the ellipse's parameter.
    func param(_ deg: Double) -> Double {
        let sc = sinCos(deg.toRadians)
        return atan2(rx * sc.sin, ry * sc.cos)
    }
    let tau = 2 * Double.pi
    let t0 = param(start)
    var dt = Swift.abs(sweep) >= 360 ? (sweep.sign == .minus ? -tau : tau) : param(start + sweep) - t0
    if Swift.abs(sweep) < 360 {
        while sweep > 0 && dt < 0 { dt += tau }
        while sweep < 0 && dt > 0 { dt -= tau }
    }
    func at(_ t: Double) -> P {
        let sc = sinCos(t)
        return P(cx + rx * sc.cos, cy + ry * sc.sin)
    }
    var ops: [Op] = []
    ops.reserveCapacity(8)
    if pie {
        ops.append(.m(P(cx, cy)))
        ops.append(.l(at(t0)))
    } else {
        ops.append(.m(at(t0)))
    }
    let n = Swift.min(Swift.max(asUsize((Swift.abs(dt) / (Double.pi / 2)).rounded(.up)), 1), 4)
    let step = dt / Double(n)
    let k = 4.0 / 3.0 * tan(step / 4)
    for i in 0 ..< n {
        let (a, e) = (t0 + step * Double(i), t0 + step * Double(i + 1))
        let (sa, se) = (sinCos(a), sinCos(e))
        let (p0, p3) = (P(cx + rx * sa.cos, cy + ry * sa.sin), P(cx + rx * se.cos, cy + ry * se.sin))
        let c1 = P(p0.x - k * rx * sa.sin, p0.y + k * ry * sa.cos)
        let c2 = P(p3.x + k * rx * se.sin, p3.y - k * ry * se.cos)
        ops.append(.c(c1, c2, p3))
    }
    if pie { ops.append(.z) }
    return ops
}

/// A font object: em size, unit, style flags, then the family name in UTF-16.
private func font(_ r: Bytes) -> PlusObj? {
    guard let emf = r.f32(4), let count = r.u32(20) else { return nil }
    let em = Double(emf)
    let n = Swift.min(Int(count), 64)
    var units: [UInt16] = []
    for i in 0 ..< n {
        guard let u = r.u16(24 + i * 2) else { return nil }
        units.append(u)
    }
    var family = String(decoding: units, as: UTF16.self)
    while family.unicodeScalars.last == "\0" { family.unicodeScalars.removeLast() }
    guard let unit = r.u32(8), let style = r.u32(12) else { return nil }
    return em.isFinite ? .font(FontObj(em: em, unit: unit, style: style, family: family)) : nil
}

/// An image object: a bitmap of raw pixels or a compressed (PNG, JPEG, GIF…) file, or a nested metafile.
private func image(_ r: Bytes, _ depth: Int) -> ImageData? {
    switch r.u32(4) {
    case 1: bitmap(r).map { .bitmap($0) }
    case 2: metafile(r, depth).map { .meta($0) }
    default: nil
    }
}

/// A metafile image: type, size, then a WMF (placeable or not) or EMF file, parsed as a picture.
private func metafile(_ r: Bytes, _ depth: Int) -> MetafilePicture? {
    guard let size = r.u32(12), let data = r.slice(16, Int(size)) ?? r.tail(16) else { return nil }
    if depth >= maxNesting { return nil }
    guard let pic = try? Metafile.parse(data, depth: depth + 1) else { return nil }
    return pic.width > 0 && pic.height > 0 ? pic : nil
}

private func bitmap(_ r: Bytes) -> Rgba? {
    guard let w32 = r.u32(8), let h32 = r.u32(12), let s32 = r.u32(16), let format = r.u32(20), let data = r.tail(28),
          let kind = r.u32(24) else { return nil }
    let (wi, hi, stride) = (Int32(bitPattern: w32), Int32(bitPattern: h32), Int32(bitPattern: s32))
    if kind == 1 { return decodeCompressedImage(data.array) }
    guard wi >= 0, hi >= 0 else { return nil }
    let (w, h) = (Int(wi), Int(hi))
    if w == 0 || h == 0 || w * h > Metafile.maxPixels { return nil }
    let bpp = Int((format >> 8) & 0xFF)
    var pal: [MetafileColor] = []
    var pixels = data
    if format & 0x0001_0000 != 0 {
        // Indexed formats carry a palette first: flags, count, ARGB entries.
        guard let count = data.u32(4) else { return nil }
        let n = Swift.min(Int(count), 256)
        for i in 0 ..< n {
            guard let c = data.u32(8 + i * 4) else { return nil }
            pal.append(argb(c))
        }
        guard let t = data.tail(8 + n * 4) else { return nil }
        pixels = t
    }
    let row = (w * bpp + 7) / 8
    let strideAbs = Swift.max(Int(stride.magnitude), row)
    var px: [UInt8] = []
    px.reserveCapacity(w * h * 4)
    for y in 0 ..< h {
        let (start, overflow) = y.multipliedReportingOverflow(by: strideAbs)
        guard !overflow, let line = pixels.slice(start, row) else { return nil }
        for x in 0 ..< w {
            let c: MetafileColor
            switch (format, bpp) {
            case (_, 1), (_, 4), (_, 8):
                guard !pal.isEmpty else { return nil }
                let bit = x * bpp
                guard let byte = line.byte(bit / 8) else { return nil }
                let i = (byte >> UInt8(8 - bpp - bit % 8)) & UInt8(truncatingIfNeeded: (1 << bpp) - 1)
                c = pal.at(Int(i)) ?? MetafileColor(0, 0, 0, 255)
            case (_, 24):
                guard let b = line.byte(x * 3), let g = line.byte(x * 3 + 1), let r = line.byte(x * 3 + 2) else { return nil }
                c = MetafileColor(r, g, b, 255)
            case (0x0002_2009, 32):
                guard let b = line.byte(x * 4), let g = line.byte(x * 4 + 1), let r = line.byte(x * 4 + 2), line.byte(x * 4 + 3) != nil else {
                    return nil
                }
                c = MetafileColor(r, g, b, 255)
            case (0x000E_200B, 32):
                guard let b = line.byte(x * 4), let g = line.byte(x * 4 + 1), let r = line.byte(x * 4 + 2), let a8 = line.byte(x * 4 + 3) else {
                    return nil
                }
                let a = UInt32(a8)
                func un(_ v: UInt8) -> UInt8 { a == 0 ? v : UInt8(Swift.min((UInt32(v) * 255 + a / 2) / a, 255)) }
                c = MetafileColor(un(r), un(g), un(b), a8)
            case (_, 32):
                guard let b = line.byte(x * 4), let g = line.byte(x * 4 + 1), let r = line.byte(x * 4 + 2), let a = line.byte(x * 4 + 3) else {
                    return nil
                }
                c = MetafileColor(r, g, b, a)
            case (0x0002_1006, 16):
                guard let lo = line.byte(x * 2), let hi = line.byte(x * 2 + 1) else { return nil }
                let v = UInt16(lo) | UInt16(hi) << 8
                func s(_ v: UInt16, _ bits: UInt32) -> UInt8 { UInt8(truncatingIfNeeded: UInt32(v) * 255 / ((1 << bits) - 1)) }
                c = MetafileColor(s(v >> 11, 5), s((v >> 5) & 0x3F, 6), s(v & 0x1F, 5), 255)
            case (_, 16):
                guard let lo = line.byte(x * 2), let hi = line.byte(x * 2 + 1) else { return nil }
                let v = UInt16(lo) | UInt16(hi) << 8
                func s(_ v: UInt16) -> UInt8 { UInt8(truncatingIfNeeded: UInt32(v & 0x1F) * 255 / 31) }
                c = MetafileColor(s(v >> 10), s(v >> 5), s(v), 255)
            default:
                return nil
            }
            px += [c[0], c[1], c[2], c[3]]
        }
    }
    // A negative stride stores the rows bottom-up.
    var img = Rgba(w: w, h: h, bottomUp: stride < 0, px: px)
    if img.bottomUp {
        DIB.flip(&img, horizontal: false, vertical: true)
        img.bottomUp = false
    }
    return img
}

/// `n` points at `off`: 16-bit integers when compressed, else 32-bit floats.
private func points(_ r: Bytes, _ off: Int, _ n: Int, _ compressed: Bool) -> [P]? {
    let n = Swift.min(n, maxPoints)
    var v: [P] = []
    v.reserveCapacity(n)
    for i in 0 ..< n {
        if compressed {
            guard let x = r.i16(off + i * 4), let y = r.i16(off + i * 4 + 2) else { return nil }
            v.append(P(Double(x), Double(y)))
        } else {
            guard let xf = r.f32(off + i * 8), let yf = r.f32(off + i * 8 + 4) else { return nil }
            let (x, y) = (Double(xf), Double(yf))
            guard x.isFinite && y.isFinite else { return nil }
            v.append(P(x, y))
        }
    }
    return v
}

/// `n` rectangles (x, y, w, h) at `off`, as `[l, t, r, b]`.
private func rects(_ r: Bytes, _ off: Int, _ n: Int, _ compressed: Bool) -> [R4]? {
    guard let pts = points(r, off, Swift.min(n, maxPoints / 2) * 2, compressed) else { return nil }
    return stride(from: 0, to: pts.count - 1, by: 2).map { R4(pts[$0].x, pts[$0].y, pts[$0].x + pts[$0 + 1].x, pts[$0].y + pts[$0 + 1].y) }
}

private func rectOps(_ r: R4) -> [Op] {
    rect(r[0], r[1], r[2], r[3])
}

private func finite(_ v: Float) -> Double? {
    v.isFinite ? Double(v) : nil
}

/// A GDI+ cardinal spline through `pts` as cubic Béziers: each segment's control points lie a third of `tension`
/// (GDI+'s default 0.5) along the neighbouring chords. `closed` joins the last point back to the first; an open
/// curve draws `segments` segments from point `offset`.
private func curveOps(_ pts: [P], _ tension: Double, closed: Bool, _ offset: Int, _ segments: Int) -> [Op] {
    let n = pts.count
    if n < 2 { return [] }
    let k = tension.clamped(0, 10) / 3
    func at(_ i: Int) -> P {
        let j = closed ? ((i % n) + n) % n : Swift.min(Swift.max(i, 0), n - 1)
        return pts.at(j) ?? P(0, 0)
    }
    let first = closed ? 0 : Swift.min(offset, n - 1)
    let count = closed ? n : Swift.min(segments, n - 1 - first)
    var ops: [Op] = [.m(at(first))]
    for i in first ..< first + count {
        let (p0, p1, p2, p3) = (at(i - 1), at(i), at(i + 1), at(i + 2))
        let c1 = P(p1.x + (p2.x - p0.x) * k, p1.y + (p2.y - p0.y) * k)
        let c2 = P(p2.x - (p3.x - p1.x) * k, p2.y - (p3.y - p1.y) * k)
        ops.append(.c(c1, c2, p2))
    }
    if closed { ops.append(.z) }
    return ops
}

private func polyOps(_ pts: [P], close: Bool) -> [Op] {
    var ops: [Op] = pts.enumerated().map { $0.offset == 0 ? .m($0.element) : .l($0.element) }
    if close { ops.append(.z) }
    return ops
}

/// An ellipse in its bounding box, as four cubic arcs.
private func ellipseOps(_ r: R4) -> [Op] {
    let (l, t, rr, b) = (r[0], r[1], r[2], r[3])
    let (cx, cy, rx, ry) = ((l + rr) / 2, (t + b) / 2, (rr - l) / 2, (b - t) / 2)
    let k = 0.552_284_75
    let (ox, oy) = (rx * k, ry * k)
    return [
        .m(P(cx + rx, cy)),
        .c(P(cx + rx, cy + oy), P(cx + ox, cy + ry), P(cx, cy + ry)),
        .c(P(cx - ox, cy + ry), P(cx - rx, cy + oy), P(cx - rx, cy)),
        .c(P(cx - rx, cy - oy), P(cx - ox, cy - ry), P(cx, cy - ry)),
        .c(P(cx + ox, cy - ry), P(cx + rx, cy - oy), P(cx + rx, cy)),
        .z,
    ]
}

/// Core fonts whose first glyphs follow the standard Macintosh order (glyph 3 is the space, glyphs 3...97 are
/// U+0020...U+007E).
private let macOrderFonts: Set<String> = [
    "arial", "arial black", "times new roman", "courier new", "verdana", "georgia", "tahoma", "trebuchet ms", "comic sans ms", "impact",
]

/// Glyph indices of a known font back to ASCII; nil when the font is unknown or a glyph is outside the ASCII range.
private func glyphsToChars(_ family: String, _ glyphs: [UInt16]) -> [UInt16]? {
    guard macOrderFonts.contains(rustASCIILowercase(String(rustTrim(family)))) else { return nil }
    var out: [UInt16] = []
    out.reserveCapacity(glyphs.count)
    for g in glyphs {
        guard (3 ... 97).contains(g) else { return nil }
        out.append(g + 29)
    }
    return out
}

/// A rough advance for a character in ems: the metafile crate has no fonts, so line breaks for wrapped strings use
/// typical proportional widths.
private func charEm(_ u: UInt16) -> Double {
    let c = Unicode.Scalar(u) ?? "x"
    switch c {
    case " ", "i", "l", "j", ".", ",", ":", ";", "'", "!", "|", "I", "f", "t", "r": return 0.3
    case "m", "w", "M", "W": return 0.85
    default:
        if ("A" ... "Z").contains(c) || ("0" ... "9").contains(c) { return 0.62 }
        if c.value >= 0x2E80 { return 1.0 }
        return 0.52
    }
}

/// Greedy word wrap of one line to `width` world units at em size `em`; a word longer than the line breaks between
/// characters.
private func wrapLine(_ line: [UInt16], _ width: Double, _ em: Double) -> [[UInt16]] {
    if em <= 0 || !width.isFinite { return [line] }
    func trimmed(_ v: ArraySlice<UInt16>) -> Int { (v.lastIndex { $0 != 0x20 }).map { $0 - v.startIndex + 1 } ?? 0 }
    func measure(_ v: ArraySlice<UInt16>) -> Double { rustSum(v.map { charEm($0) * em }) }

    var out: [[UInt16]] = []
    var cur: [UInt16] = []
    var curTotalW = 0.0

    // `split_inclusive` on spaces: each word keeps its trailing space.
    var words: [ArraySlice<UInt16>] = []
    var s = line.startIndex
    for (i, u) in line.enumerated() where u == 0x20 {
        words.append(line[s ... i])
        s = i + 1
    }
    if s < line.endIndex { words.append(line[s...]) }

    for word in words {
        let nNonSpace = trimmed(word)
        let wordNonSpaceW = measure(word.prefix(nNonSpace))
        let wordTotalW = measure(word)

        if cur.isEmpty {
            if wordNonSpaceW <= width {
                cur += word
                curTotalW = wordTotalW
                continue
            }
        } else if curTotalW + wordNonSpaceW <= width {
            cur += word
            curTotalW += wordTotalW
            continue
        }

        if !cur.isEmpty {
            cur.removeSubrange(trimmed(cur[...])...)
            out.append(cur)
            cur = []
        }

        if wordNonSpaceW <= width {
            cur += word
            curTotalW = wordTotalW
            continue
        }

        // A word wider than the line on its own: break it between characters.
        var curW = 0.0
        for u in word {
            let uW = charEm(u) * em
            if cur.isEmpty {
                cur.append(u)
                curW = uW
            } else if curW + uW <= width {
                cur.append(u)
                curW += uW
            } else {
                cur.removeSubrange(trimmed(cur[...])...)
                out.append(cur)
                cur = [u]
                curW = uW
            }
        }
        curTotalW = curW
    }
    cur.removeSubrange(trimmed(cur[...])...)
    out.append(cur)
    return out
}
