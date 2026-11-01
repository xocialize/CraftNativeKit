// CNMetafile — clipping drawn output to a convex device polygon (EMF+ clip rectangles, and clip paths and
// regions that are convex; others are reduced to their bounding rectangle). Shapes wholly inside pass
// unchanged; shapes crossing the edge are flattened and cut: fills with Sutherland–Hodgman per subpath, outlines
// with Cyrus–Beck per segment. Bitmaps are cropped (and masked outside a non-rectangular polygon) and text gets
// the polygon's bounding rectangle. Port of deckcraft crates/metafile/src/cliprect.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import CNCore

enum ClipRect {
    /// Line segments per Bézier when a crossing shape is flattened.
    private static let curveSteps = 16

    /// The bounding box `[l, t, r, b]` of the points in `ops` (control points included).
    static func opsBBox(_ ops: [Op]) -> R4? {
        var b: R4?
        func add(_ p: P) {
            let v = b ?? R4(p.x, p.y, p.x, p.y)
            b = R4(v[0].rustMin(p.x), v[1].rustMin(p.y), v[2].rustMax(p.x), v[3].rustMax(p.y))
        }
        for op in ops {
            switch op {
            case .m(let p), .l(let p): add(p)
            case .c(let a, let c, let d):
                add(a)
                add(c)
                add(d)
            case .z: break
            }
        }
        return b
    }

    static func intersect(_ a: R4, _ b: R4) -> R4 {
        let r = R4(a[0].rustMax(b[0]), a[1].rustMax(b[1]), a[2].rustMin(b[2]), a[3].rustMin(b[3]))
        // An empty intersection stays empty (zero size) so it clips everything away.
        return r[2] < r[0] || r[3] < r[1] ? R4(r[0], r[1], r[0], r[1]) : r
    }

    /// A rectangle `[l, t, r, b]` as a polygon.
    static func rectPoly(_ r: R4) -> [P] {
        [P(r[0], r[1]), P(r[2], r[1]), P(r[2], r[3]), P(r[0], r[3])]
    }

    /// The bounding box of a point list.
    static func ptsBBox(_ pts: [P]) -> R4? {
        guard let f = pts.first else { return nil }
        return pts.dropFirst().reduce(R4(f.x, f.y, f.x, f.y)) { v, p in
            R4(v[0].rustMin(p.x), v[1].rustMin(p.y), v[2].rustMax(p.x), v[3].rustMax(p.y))
        }
    }

    private static func cross(_ a: P, _ b: P, _ p: P) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }

    /// A convex clip polygon with positive orientation, or nil when `pts` is not convex (or degenerate);
    /// duplicate and collinear points are dropped.
    static func convex(_ pts: [P]) -> [P]? {
        var v: [P] = []
        v.reserveCapacity(pts.count)
        for p in pts {
            guard p.isFinite else { return nil }
            if let q = v.last, !(Swift.abs(q.x - p.x) > 1e-9 || Swift.abs(q.y - p.y) > 1e-9) { continue }
            v.append(p)
        }
        while v.count > 1 && v.first == v.last { v.removeLast() }
        let area = rustSum((0 ..< v.count).map { cross(P(0, 0), v[$0], v[($0 + 1) % v.count]) })
        if v.count < 3 || Swift.abs(area) < 1e-12 { return nil }
        if area < 0 { v.reverse() }
        let n = v.count
        var out: [P] = []
        out.reserveCapacity(n)
        for i in 0 ..< n {
            let c = cross(v[(i + n - 1) % n], v[i], v[(i + 1) % n])
            if c < -1e-9 * (1 + Swift.abs(area)) { return nil }
            if Swift.abs(c) > 1e-12 { out.append(v[i]) }
        }
        return out.count >= 3 ? out : nil
    }

    private static func insidePoly(_ clip: [P], _ p: P) -> Bool {
        (0 ..< clip.count).allSatisfy { cross(clip[$0], clip[($0 + 1) % clip.count], p) >= -1e-9 }
    }

    /// Whether the clip polygon is an axis-aligned rectangle.
    private static func isRect(_ clip: [P]) -> Bool {
        guard let b = ptsBBox(clip) else { return false }
        return clip.count == 4 && clip.allSatisfy { ($0.x == b[0] || $0.x == b[2]) && ($0.y == b[1] || $0.y == b[3]) }
    }

    /// Sutherland–Hodgman: `poly` cut by convex `clip`.
    static func clipPolygon(_ poly: [P], _ clip: [P]) -> [P] {
        if poly.count.multipliedReportingOverflow(by: clip.count).overflow || poly.count * clip.count > 1_000_000 { return [] }
        var poly = poly
        for i in 0 ..< clip.count {
            let (work, o) = poly.count.multipliedReportingOverflow(by: clip.count - i)
            if o || work > 1_000_000 { return [] }
            let (a, b) = (clip[i], clip[(i + 1) % clip.count])
            func keep(_ p: P) -> Bool { cross(a, b, p) >= 0 }
            func cut(_ p: P, _ q: P) -> P {
                let (cp, cq) = (cross(a, b, p), cross(a, b, q))
                let t = cp / (cp - cq)
                return P(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t)
            }
            var next: [P] = []
            next.reserveCapacity(poly.count + 4)
            for j in 0 ..< poly.count {
                let (p, q) = (poly[(j + poly.count - 1) % poly.count], poly[j])
                switch (keep(p), keep(q)) {
                case (true, true): next.append(q)
                case (true, false): next.append(cut(p, q))
                case (false, true):
                    next.append(cut(p, q))
                    next.append(q)
                case (false, false): break
                }
            }
            poly = next
            if poly.isEmpty { break }
        }
        return poly
    }

    private static func disjoint(_ b: R4, _ c: R4) -> Bool {
        b[2] < c[0] || b[0] > c[2] || b[3] < c[1] || b[1] > c[3] || c[2] <= c[0] || c[3] <= c[1]
    }

    private static func bboxInside(_ b: R4, _ clip: [P]) -> Bool {
        rectPoly(b).allSatisfy { insidePoly(clip, $0) }
    }

    /// Clips one drawn item to a convex device polygon; a shape that is both filled and stroked comes back as
    /// two items. An empty polygon clips everything away.
    static func clipRaw(_ raw: Raw, _ clip: [P]) -> [Raw] {
        guard clip.count >= 3, let cb = ptsBBox(clip) else { return [] }
        switch raw {
        case .path(let ops, let fill, let stroke, let evenOdd, let region):
            guard let b = opsBBox(ops) else { return [] }
            if bboxInside(b, clip) { return [raw] }
            if disjoint(b, cb) { return [] }
            let subs = flatten(ops)
            var out: [Raw] = []
            if fill != nil {
                let f = clipFill(subs, clip)
                if !f.isEmpty { out.append(.path(ops: f, fill: fill, stroke: nil, evenOdd: evenOdd, region: region)) }
            }
            if stroke != nil {
                let s = clipStroke(subs, clip)
                if !s.isEmpty { out.append(.path(ops: s, fill: nil, stroke: stroke, evenOdd: evenOdd, region: region)) }
            }
            return out
        case .pattern(let ops, let evenOdd, let tile, let region):
            guard let b = opsBBox(ops) else { return [] }
            if bboxInside(b, clip) { return [raw] }
            if disjoint(b, cb) { return [] }
            let f = clipFill(flatten(ops), clip)
            return f.isEmpty ? [] : [.pattern(ops: f, evenOdd: evenOdd, tile: tile, region: region)]
        case .bitmap(let rect, let img, let region):
            guard let (rect, img) = crop(rect, img, clip) else { return [] }
            return [.bitmap(rect: rect, img: img, region: region)]
        case .text(var t, let region):
            // Text clips to a rectangle: the one around the polygon.
            let cur = t.clip.map { intersect(cb, R4(Double($0[0]), Double($0[1]), Double($0[2]), Double($0[3]))) } ?? cb
            t.clip = SIMD4<Float>(Float(cur[0]), Float(cur[1]), Float(cur[2]), Float(cur[3]))
            return [.text(t, region: region)]
        }
    }

    /// Subpaths as point lists with their closed flag.
    static func flatten(_ ops: [Op]) -> [(pts: [P], closed: Bool)] {
        var subs: [(pts: [P], closed: Bool)] = []
        for op in ops {
            switch op {
            case .m(let p): subs.append(([p], false))
            case .l(let p):
                if subs.isEmpty { subs.append(([p], false)) } else { subs[subs.count - 1].pts.append(p) }
            case .c(let a, let b, let d):
                guard !subs.isEmpty, let p0 = subs[subs.count - 1].pts.last else { continue }
                for i in 1 ... curveSteps {
                    let t = Double(i) / Double(curveSteps)
                    let u = 1 - t
                    let k = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
                    subs[subs.count - 1].pts.append(P(
                        k.0 * p0.x + k.1 * a.x + k.2 * b.x + k.3 * d.x,
                        k.0 * p0.y + k.1 * a.y + k.2 * b.y + k.3 * d.y
                    ))
                }
            case .z:
                guard !subs.isEmpty else { continue }
                subs[subs.count - 1].closed = true
                // Drawing after a close starts from the subpath's first point.
                if let f = subs[subs.count - 1].pts.first { subs.append(([f], false)) }
            }
        }
        return subs.filter { $0.pts.count > 1 }
    }

    private static func clipFill(_ subs: [(pts: [P], closed: Bool)], _ clip: [P]) -> [Op] {
        var ops: [Op] = []
        for s in subs {
            let poly = clipPolygon(s.pts, clip)
            if poly.count >= 3 {
                ops.append(.m(poly[0]))
                ops += poly.dropFirst().map { .l($0) }
                ops.append(.z)
            }
        }
        return ops
    }

    private static func clipStroke(_ subs: [(pts: [P], closed: Bool)], _ clip: [P]) -> [Op] {
        var ops: [Op] = []
        for s in subs {
            var pts = s.pts
            if s.closed, let f = pts.first { pts.append(f) }
            var last: P?
            for k in 0 ..< Swift.max(pts.count - 1, 0) {
                guard let (a, b) = segment(pts[k], pts[k + 1], clip) else {
                    last = nil
                    continue
                }
                if last != a { ops.append(.m(a)) }
                ops.append(.l(b))
                last = b
            }
        }
        return ops
    }

    /// Cyrus–Beck: the part of segment `a`–`b` inside convex `clip`.
    private static func segment(_ a: P, _ b: P, _ clip: [P]) -> (P, P)? {
        let d = P(b.x - a.x, b.y - a.y)
        var (t0, t1) = (0.0, 1.0)
        for i in 0 ..< clip.count {
            let (e0, e1) = (clip[i], clip[(i + 1) % clip.count])
            // Inside is cross(e0, e1, p) >= 0, linear in t along the segment.
            let f0 = cross(e0, e1, a)
            let df = (e1.x - e0.x) * d.y - (e1.y - e0.y) * d.x
            if df == 0 {
                if f0 < 0 { return nil }
            } else {
                let t = -f0 / df
                if df > 0 { t0 = t0.rustMax(t) } else { t1 = t1.rustMin(t) }
            }
        }
        return t0 <= t1 ? (P(a.x + d.x * t0, a.y + d.y * t0), P(a.x + d.x * t1, a.y + d.y * t1)) : nil
    }

    /// Crops a bitmap drawn into `rect` = `[x, y, w, h]` (device, positive extents) to the clip polygon's box;
    /// pixels outside a non-rectangular polygon turn transparent.
    private static func crop(_ rect: R4, _ img: Rgba, _ clip: [P]) -> (R4, Rgba)? {
        let (x, y, w, h) = (rect[0], rect[1], rect[2], rect[3])
        let b = R4(x, y, x + w, y + h)
        if bboxInside(b, clip) { return (rect, img) }
        guard let c = ptsBBox(clip) else { return nil }
        if disjoint(b, c) || w <= 0 || h <= 0 || img.w == 0 || img.h == 0 { return nil }
        let i = intersect(b, c)
        let (kx, ky) = (Double(img.w) / w, Double(img.h) / h)
        let x0 = Swift.min(asUsize(((i[0] - x) * kx).rounded(.down).rustMax(0)), img.w)
        let x1 = Swift.min(asUsize(((i[2] - x) * kx).rounded(.up).rustMax(0)), img.w)
        let y0 = Swift.min(asUsize(((i[1] - y) * ky).rounded(.down).rustMax(0)), img.h)
        let y1 = Swift.min(asUsize(((i[3] - y) * ky).rounded(.up).rustMax(0)), img.h)
        if x1 <= x0 || y1 <= y0 { return nil }
        let mask = !isRect(clip)
        let total = (x1 - x0).multipliedReportingOverflow(by: y1 - y0)
        let work = total.partialValue.multipliedReportingOverflow(by: clip.count)
        if mask && (total.overflow || work.overflow || work.partialValue > 5_000_000) { return nil }
        let rowLen = (x1 - x0) * 4
        var px: [UInt8] = []
        px.reserveCapacity(rowLen * (y1 - y0))
        for row in y0 ..< y1 {
            // Rows are top-down unless the image says otherwise.
            let r = img.bottomUp ? img.h - 1 - row : row
            let s = (r * img.w + x0) * 4
            guard s >= 0, s + rowLen <= img.px.count else { return nil }
            let start = px.count
            px.append(contentsOf: img.px[s ..< s + rowLen])
            if mask {
                let cy = y + (Double(row) + 0.5) / ky
                for k in 0 ..< (x1 - x0) {
                    let cx = x + (Double(x0 + k) + 0.5) / kx
                    if !insidePoly(clip, P(cx, cy)) { px[start + k * 4 + 3] = 0 }
                }
            }
        }
        let out = R4(x + Double(x0) / kx, y + Double(y0) / ky, Double(x1 - x0) / kx, Double(y1 - y0) / ky)
        return (out, Rgba(w: x1 - x0, h: y1 - y0, bottomUp: false, px: px))
    }
}
