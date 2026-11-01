// CNMetafile — placing a picture on a target (a page or a device): the fitted transform, paths in target units and
// bitmaps as target rectangles. The rasteriser and the PDF writer only paint the result. Port of deckcraft
// crates/metafile/src/place.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors), with the pieces
// of kurbo it uses (Affine, BezPath, Rect; MIT OR Apache-2.0, © the kurbo authors) as small local types.
// `Metafile.cropWindow` and the `.wordCraft` crop rule are from WordCraft crates/metafile/src/place.rs at fd7f6621
// (MIT OR Apache-2.0, © ArtCraft Team and the WordCraft contributors) (0cca2f7d, fc5063c3).
import CoreGraphics
import CNCore

/// Placed coordinates past this (target units) are far off any page; such items are left out.
private let maxCoord = 1e6
/// Smallest placed bitmap side (target units), so the stretch onto it is never singular.
private let minBitmapSide = 1e-6
/// Maximum aggregate path elements retained in placed output.
private let maxPlacedElements = 500_000

/// An affine map `[a, b, c, d, e, f]`: `x' = a·x + c·y + e`, `y' = b·x + d·y + f` (kurbo's `Affine`, and
/// `CGAffineTransform`'s order).
public struct MetafileAffine: Equatable, Sendable {
    public var coeffs: [Double]

    public init(_ coeffs: [Double]) {
        self.coeffs = coeffs
    }

    public static func translate(_ x: Double, _ y: Double) -> MetafileAffine { MetafileAffine([1, 0, 0, 1, x, y]) }
    public static func scale(_ sx: Double, _ sy: Double) -> MetafileAffine { MetafileAffine([sx, 0, 0, sy, 0, 0]) }

    /// `a * b`: `b` first, then `a`.
    public static func * (a: MetafileAffine, b: MetafileAffine) -> MetafileAffine {
        let (s, o) = (a.coeffs, b.coeffs)
        return MetafileAffine([
            s[0] * o[0] + s[2] * o[1],
            s[1] * o[0] + s[3] * o[1],
            s[0] * o[2] + s[2] * o[3],
            s[1] * o[2] + s[3] * o[3],
            s[0] * o[4] + s[2] * o[5] + s[4],
            s[1] * o[4] + s[3] * o[5] + s[5],
        ])
    }

    public func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let c = coeffs
        return SIMD2(c[0] * p.x + c[2] * p.y + c[4], c[1] * p.x + c[3] * p.y + c[5])
    }

    public var determinant: Double { coeffs[0] * coeffs[3] - coeffs[1] * coeffs[2] }

    /// The bounding box of `rect` after the map.
    public func transformRectBBox(_ r: MetafileRect) -> MetafileRect {
        let p00 = apply(SIMD2(r.x0, r.y0))
        let p01 = apply(SIMD2(r.x0, r.y1))
        let p10 = apply(SIMD2(r.x1, r.y0))
        let p11 = apply(SIMD2(r.x1, r.y1))
        return MetafileRect.fromPoints(p00, p01).union(.fromPoints(p10, p11))
    }

    public var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: coeffs[0], b: coeffs[1], c: coeffs[2], d: coeffs[3], tx: coeffs[4], ty: coeffs[5])
    }
}

/// A rectangle by its corners (kurbo's `Rect`).
public struct MetafileRect: Equatable, Sendable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        (self.x0, self.y0, self.x1, self.y1) = (x0, y0, x1, y1)
    }

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }

    static func fromPoints(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> MetafileRect {
        MetafileRect(p.x.rustMin(q.x), p.y.rustMin(q.y), p.x.rustMax(q.x), p.y.rustMax(q.y))
    }

    func union(_ o: MetafileRect) -> MetafileRect {
        MetafileRect(x0.rustMin(o.x0), y0.rustMin(o.y0), x1.rustMax(o.x1), y1.rustMax(o.y1))
    }

    func unionPoint(_ p: SIMD2<Double>) -> MetafileRect {
        MetafileRect(x0.rustMin(p.x), y0.rustMin(p.y), x1.rustMax(p.x), y1.rustMax(p.y))
    }

    public var cgRect: CGRect { CGRect(x: x0, y: y0, width: width, height: height) }
}

/// One element of a placed path (kurbo's `PathEl`).
public enum MetafilePathElement: Equatable, Sendable {
    case moveTo(SIMD2<Double>)
    case lineTo(SIMD2<Double>)
    case curveTo(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)
    case closePath
}

/// A placed path (kurbo's `BezPath`).
public struct MetafilePath: Equatable, Sendable {
    public var elements: [MetafilePathElement] = []

    public init(_ elements: [MetafilePathElement] = []) {
        self.elements = elements
    }

    public var isEmpty: Bool { elements.isEmpty }

    public static func * (a: MetafileAffine, p: MetafilePath) -> MetafilePath {
        MetafilePath(p.elements.map {
            switch $0 {
            case .moveTo(let q): .moveTo(a.apply(q))
            case .lineTo(let q): .lineTo(a.apply(q))
            case .curveTo(let q1, let q2, let q3): .curveTo(a.apply(q1), a.apply(q2), a.apply(q3))
            case .closePath: .closePath
            }
        })
    }

    /// The exact bounding box of the segments (curve extrema included, as kurbo computes it); zero for a path
    /// with no segments.
    public var boundingBox: MetafileRect {
        var bbox: MetafileRect?
        var start = SIMD2<Double>(0, 0)
        var last = SIMD2<Double>(0, 0)
        var started = false
        func add(_ r: MetafileRect) { bbox = bbox.map { $0.union(r) } ?? r }
        for el in elements {
            switch el {
            case .moveTo(let p):
                (start, last, started) = (p, p, true)
            case .lineTo(let p):
                if !started { (start, last, started) = (p, p, true) }
                add(.fromPoints(last, p))
                last = p
            case .curveTo(let p1, let p2, let p3):
                if !started { (start, last, started) = (p3, p3, true) }
                add(cubicBBox(last, p1, p2, p3))
                last = p3
            case .closePath:
                // The path's own construction never starts with a close.
                if started && last != start {
                    add(.fromPoints(last, start))
                    last = start
                }
            }
        }
        return bbox ?? MetafileRect(0, 0, 0, 0)
    }

    public var cgPath: CGPath {
        let path = CGMutablePath()
        for el in elements {
            switch el {
            case .moveTo(let p): path.move(to: CGPoint(x: p.x, y: p.y))
            case .lineTo(let p): path.addLine(to: CGPoint(x: p.x, y: p.y))
            case .curveTo(let a, let b, let c):
                path.addCurve(to: CGPoint(x: c.x, y: c.y), control1: CGPoint(x: a.x, y: a.y), control2: CGPoint(x: b.x, y: b.y))
            case .closePath: path.closeSubpath()
            }
        }
        return path
    }
}

/// One item of a placed picture, in target units. `region` is the device-context clip (nil: the default clip).
public enum MetafilePlacedItem: Equatable, Sendable {
    /// A filled and/or stroked path. The stroke width is in target units; 0 is a cosmetic hairline that the
    /// renderer draws at its minimum width.
    case path(path: MetafilePath, fill: MetafileColor?, stroke: (color: MetafileColor, width: Double)?, evenOdd: Bool, region: MetafilePath?)
    /// `MetafilePicture.items[index]`, a bitmap, stretched into `rect`.
    case bitmap(index: Int, rect: MetafileRect, region: MetafilePath?)
    /// `MetafilePicture.items[index]`, a pattern fill: `path` (target units) filled with the item's tile repeated;
    /// `tile` maps tile pixels to target units.
    case pattern(index: Int, path: MetafilePath, evenOdd: Bool, tile: MetafileAffine, region: MetafilePath?)
    /// `MetafilePicture.items[index]`, a text string: `transform` maps its text space to target units; `clip`
    /// (target units) bounds what it draws.
    case text(index: Int, transform: MetafileAffine, clip: MetafileRect?, region: MetafilePath?)

    public static func == (a: MetafilePlacedItem, b: MetafilePlacedItem) -> Bool {
        switch (a, b) {
        case let (.path(p1, f1, s1, e1, r1), .path(p2, f2, s2, e2, r2)):
            p1 == p2 && f1 == f2 && s1?.color == s2?.color && s1?.width == s2?.width && e1 == e2 && r1 == r2
        case let (.bitmap(i1, r1, g1), .bitmap(i2, r2, g2)):
            i1 == i2 && r1 == r2 && g1 == g2
        case let (.pattern(i1, p1, e1, t1, g1), .pattern(i2, p2, e2, t2, g2)):
            i1 == i2 && p1 == p2 && e1 == e2 && t1 == t2 && g1 == g2
        case let (.text(i1, t1, c1, g1), .text(i2, t2, c2, g2)):
            i1 == i2 && t1 == t2 && c1 == c2 && g1 == g2
        default:
            false
        }
    }
}

/// How `fit` and `place` read crop fractions (left, top, right, bottom) that leave little of an axis.
public enum MetafileCropRule: Sendable {
    /// deckcraft's: each side is clamped to 0–0.95 and at least 5% of an axis shows, so a sliver crop is widened
    /// to 5% (the picture comes out smaller than the file says).
    case deckcraft
    /// WordCraft's (`crop_window`): each side is clamped to 0–1 and at least 0.5% of an axis shows, so a sliver
    /// crop (a header bar that is 2.7% of a page-sized metafile) is drawn at the size the file gives.
    case wordCraft
}

extension Metafile {
    /// The least of a source axis WordCraft's crop keeps (0.5%). Layout makes a picture's frame at most 4000 pt a
    /// side, so the whole source then spans at most 800,000 pt and stays inside the ±1e6 that `place` keeps.
    public static let minVisibleCrop = 0.005

    /// The part of a picture's source that `crop` (left, top, right, bottom fractions of the source) keeps, as
    /// fractions of the source: `[left, top, width, height]`, bitmap or metafile alike (WordCraft's `crop_window`).
    /// Each side is taken as 0–1 (junk as 0). When the two sides of an axis leave less than 0.5% of it, the left
    /// (top) side stands and 0.5% shows.
    public static func cropWindow(_ crop: SIMD4<Float>) -> SIMD4<Double> {
        func side(_ v: Float) -> Double { v.isFinite ? Double(v.clamped(0, 1)) : 0 }
        func axis(_ lo: Double, _ hi: Double) -> (Double, Double) {
            let lo = Swift.min(lo, 1 - minVisibleCrop)
            return (lo, Swift.max(1 - lo - hi, minVisibleCrop))
        }
        let (x, w) = axis(side(crop[0]), side(crop[2]))
        let (y, h) = axis(side(crop[1]), side(crop[3]))
        return SIMD4(x, y, w, h)
    }
}

extension MetafilePicture {
    /// Whether the picture has a finite, positive size, so it can be fitted into a frame.
    public var hasSize: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }

    /// The transform that fits the picture into `r` with the crop fractions `crop` (left, top, right, bottom)
    /// removed first: the visible part fills `r`. nil for a degenerate size. `rule` says how a crop that leaves
    /// little or nothing of an axis is read (`MetafileCropRule`).
    public func fit(_ r: MetafileRect, crop: SIMD4<Float>, rule: MetafileCropRule = .deckcraft) -> MetafileAffine? {
        let (w, h) = (Double(width), Double(height))
        let (cl, ct, sx, sy): (Double, Double, Double, Double)
        switch rule {
        case .deckcraft:
            func frac(_ v: Float) -> Double { v.isFinite ? Double(v.clamped(0, 0.95)) : 0 }
            let (cr, cb) = (frac(crop[2]), frac(crop[3]))
            (cl, ct) = (frac(crop[0]), frac(crop[1]))
            sx = r.width / (w * (1 - cl - cr).rustMax(0.05))
            sy = r.height / (h * (1 - ct - cb).rustMax(0.05))
        case .wordCraft:
            let c = Metafile.cropWindow(crop)
            (cl, ct) = (c[0], c[1])
            sx = r.width / (w * c[2])
            sy = r.height / (h * c[3])
        }
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return nil }
        return .translate(r.x0 - cl * w * sx, r.y0 - ct * h * sy) * .scale(sx, sy)
    }

    /// The items placed into `r` with `crop` applied (read by `rule`, as for `fit`). Items that are not finite or
    /// reach past ±1e6 target units are left out (they are far off any page), as are bitmaps with no area. Stroke
    /// widths are scaled to target units (along the mean axis scale, so a non-uniform fit keeps strokes even).
    public func place(_ r: MetafileRect, crop: SIMD4<Float>, rule: MetafileCropRule = .deckcraft) -> [MetafilePlacedItem] {
        guard let tf = fit(r, crop: crop, rule: rule) else { return [] }
        let c = tf.coeffs
        let k = (Swift.abs(c[0]) + Swift.abs(c[3])) / 2
        var out: [MetafilePlacedItem] = []
        out.reserveCapacity(items.count)
        var totalElements = 0
        // Consecutive items usually share one region: it is placed once.
        var cached: (key: [SIMD4<Float>]?, value: MetafilePath??)?
        func region(_ reg: [SIMD4<Float>]?) -> MetafilePath?? {
            if let c = cached, c.key == reg { return c.value }
            let v = placedRegion(tf, reg)
            cached = (reg, v)
            return v
        }
        for (index, item) in items.enumerated() {
            if totalElements >= maxPlacedElements { break }
            switch item {
            case .path(let segs, let fill, let stroke, let evenOdd, let reg):
                let path = tf * bez(segs)
                guard let region = region(reg) else { continue }
                if inRange(path.boundingBox) {
                    totalElements = totalElements.addingSaturating(path.elements.count)
                    let s = stroke.map { (color: $0.color, width: Double($0.width) * k) }
                    out.append(.path(path: path, fill: fill, stroke: s, evenOdd: evenOdd, region: region))
                }
            case .pattern(let segs, let evenOdd, let t, let reg):
                let path = tf * bez(segs)
                guard let region = region(reg) else { continue }
                let tile = tf * .translate(Double(t.origin[0]), Double(t.origin[1])) * .scale(Double(t.cell[0]), Double(t.cell[1]))
                let det = tile.determinant
                if inRange(path.boundingBox) && det.isFinite && Swift.abs(det) > 1e-12 {
                    totalElements = totalElements.addingSaturating(path.elements.count)
                    out.append(.pattern(index: index, path: path, evenOdd: evenOdd, tile: tile, region: region))
                }
            case .text(let t):
                let transform = tf * MetafileAffine(t.transform)
                guard let region = region(t.region) else { continue }
                let clip = t.clip.map {
                    tf.transformRectBBox(MetafileRect(Double($0[0]), Double($0[1]), Double($0[2]), Double($0[3])))
                }
                let cc = transform.coeffs
                let origin = MetafileRect(cc[4], cc[5], cc[4], cc[5])
                if inRange(origin) && cc.allSatisfy({ $0.isFinite && Swift.abs($0) <= maxCoord }) && (clip.map(inRange) ?? true) {
                    out.append(.text(index: index, transform: transform, clip: clip, region: region))
                }
            case .bitmap(let rect, _, _, _, let reg):
                let (x0, y0) = (Double(rect[0]), Double(rect[1]))
                let placed = tf.transformRectBBox(MetafileRect(x0, y0, x0 + Double(rect[2]), y0 + Double(rect[3])))
                guard let region = region(reg) else { continue }
                if inRange(placed) && placed.width > minBitmapSide && placed.height > minBitmapSide {
                    out.append(.bitmap(index: index, rect: placed, region: region))
                }
            }
        }
        return out
    }
}

extension MetafileItem {
    /// Takes a bitmap's pixels out of the item (its geometry stays) and returns them as (width, height, RGBA) when a
    /// renderer can draw them: both sides in 1...`Metafile.maxBitmapSide` and exactly that many pixels. nil for
    /// paths and for bitmaps that cannot be drawn.
    public mutating func takePixels() -> (width: UInt32, height: UInt32, rgba: [UInt8])? {
        guard case .bitmap(let rect, let w, let h, let px, let region) = self else { return nil }
        self = .bitmap(rect: rect, width: w, height: h, rgba: [], region: region)
        let sides = (1 ... Metafile.maxBitmapSide).contains(w) && (1 ... Metafile.maxBitmapSide).contains(h)
        return sides && px.count == Int(w) * Int(h) * 4 ? (w, h, px) : nil
    }
}

/// The device-context clip in target units. `.some(nil)` is the default clip. nil means the region does not meet
/// the page, so the item draws nothing.
private func placedRegion(_ tf: MetafileAffine, _ region: [SIMD4<Float>]?) -> MetafilePath?? {
    guard let rects = region else { return .some(nil) }
    var path = MetafilePath()
    for q in rects {
        let r = tf.transformRectBBox(MetafileRect(Double(q[0]), Double(q[1]), Double(q[2]), Double(q[3])))
        if inRange(r) && r.width > 1e-9 && r.height > 1e-9 {
            path.elements += [.moveTo(SIMD2(r.x0, r.y0)), .lineTo(SIMD2(r.x1, r.y0)), .lineTo(SIMD2(r.x1, r.y1)), .lineTo(SIMD2(r.x0, r.y1)), .closePath]
        }
    }
    return path.isEmpty ? nil : .some(path)
}

/// Segments as a path. A segment after a close opens a new subpath at the last start point.
private func bez(_ segs: [MetafileSeg]) -> MetafilePath {
    var p: [MetafilePathElement] = []
    p.reserveCapacity(segs.count)
    var start = SIMD2<Double>(0, 0)
    var open = false
    for s in segs {
        switch s {
        case .move(let x, let y):
            start = SIMD2(Double(x), Double(y))
            p.append(.moveTo(start))
            open = true
        case .line(let x, let y):
            if !open { p.append(.moveTo(start)) }
            p.append(.lineTo(SIMD2(Double(x), Double(y))))
            open = true
        case .cubic(let a, let b, let c, let d, let e, let f):
            if !open { p.append(.moveTo(start)) }
            p.append(.curveTo(SIMD2(Double(a), Double(b)), SIMD2(Double(c), Double(d)), SIMD2(Double(e), Double(f))))
            open = true
        case .close:
            if open { p.append(.closePath) }
            open = false
        }
    }
    return MetafilePath(p)
}

/// Whether a placed box is finite and within ±`maxCoord`.
private func inRange(_ b: MetafileRect) -> Bool {
    [b.x0, b.y0, b.x1, b.y1].allSatisfy { $0.isFinite && Swift.abs($0) < maxCoord }
}

/// kurbo's `CubicBez` bounding box: the end points and the points at the derivative's roots in (0, 1).
private func cubicBBox(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ p3: SIMD2<Double>) -> MetafileRect {
    var ts: [Double] = []
    func oneCoord(_ d0: Double, _ d1: Double, _ d2: Double) {
        let a = d0 - 2 * d1 + d2
        let b = 2 * (d1 - d0)
        for t in solveQuadratic(d0, b, a) where t > 0 && t < 1 { ts.append(t) }
    }
    let (d0, d1, d2) = (p1 - p0, p2 - p1, p3 - p2)
    oneCoord(d0.x, d1.x, d2.x)
    oneCoord(d0.y, d1.y, d2.y)
    var bbox = MetafileRect.fromPoints(p0, p3)
    for t in ts.sorted() {
        let mt = 1 - t
        let v = p0 * (mt * mt * mt) + (p1 * (mt * mt * 3) + (p2 * (mt * 3) + p3 * t) * t) * t
        bbox = bbox.unionPoint(v)
    }
    return bbox
}

/// kurbo's `solve_quadratic`: real roots of `c0 + c1·x + c2·x²`.
private func solveQuadratic(_ c0: Double, _ c1: Double, _ c2: Double) -> [Double] {
    let sc0 = c0 * (1 / c2)
    let sc1 = c1 * (1 / c2)
    if !sc0.isFinite || !sc1.isFinite {
        // c2 is zero or very small, treat as linear eqn
        let root = -c0 / c1
        if root.isFinite { return [root] }
        return c0 == 0 && c1 == 0 ? [0] : []
    }
    let arg = sc1 * sc1 - 4 * sc0
    let root1: Double
    if !arg.isFinite {
        // Likely, calculation of sc1 * sc1 overflowed. Find one root using sc1 x + x² = 0, other root as
        // sc0 / root1.
        root1 = -sc1
    } else {
        if arg < 0 { return [] }
        if arg == 0 { return [-0.5 * sc1] }
        root1 = -0.5 * (sc1 + Double(signOf: sc1, magnitudeOf: arg.squareRoot()))
    }
    let root2 = sc0 / root1
    if root2.isFinite {
        return root2 > root1 ? [root1, root2] : [root2, root1]
    }
    return [root1]
}
