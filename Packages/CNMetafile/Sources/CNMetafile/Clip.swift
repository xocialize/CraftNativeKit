// CNMetafile — clipping regions for EMF and WMF (MS-EMF 2.3.12, MS-WMF 2.3.5). Port of deckcraft
// crates/metafile/src/clip.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// A region is a set of axis-aligned rectangles `[x0, y0, x1, y1]` in device units: nil is the default clip
// (the whole surface), `[]` draws nothing, and a list is their union, as GDI stores a region (`RGNDATA`).
// Counts are capped so a hostile file cannot grow the set without bound; past the cap, extra rectangles are
// dropped, which can only hide drawing.
import CNCore

typealias R4 = SIMD4<Double>

enum Clip {
    /// Rectangles kept from one region. Past this, further rectangles are dropped.
    static let maxClipRects = 64

    static let rgnAnd: UInt32 = 1
    static let rgnOr: UInt32 = 2
    static let rgnXor: UInt32 = 3
    static let rgnDiff: UInt32 = 4
    static let rgnCopy: UInt32 = 5

    /// A rectangle `[x0, y0, x1, y1]` with a positive area, or nil.
    static func normalize(_ rect: R4) -> R4? {
        let (l, t, r, b) = (rect[0], rect[1], rect[2], rect[3])
        guard l.isFinite, t.isFinite, r.isFinite, b.isFinite else { return nil }
        let (x0, x1) = (l.rustMin(r), l.rustMax(r))
        let (y0, y1) = (t.rustMin(b), t.rustMax(b))
        return x1 - x0 > 1e-6 && y1 - y0 > 1e-6 ? R4(x0, y0, x1, y1) : nil
    }

    private static func intersection(_ a: R4, _ b: R4) -> R4? {
        let (x0, y0) = (a[0].rustMax(b[0]), a[1].rustMax(b[1]))
        let (x1, y1) = (a[2].rustMin(b[2]), a[3].rustMin(b[3]))
        guard x1 - x0 > 1e-6, y1 - y0 > 1e-6, x0.isFinite, y0.isFinite, x1.isFinite, y1.isFinite else { return nil }
        return R4(x0, y0, x1, y1)
    }

    /// `a` with `b` removed, as up to four rectangles.
    private static func subtractOne(_ a: R4, _ b: R4) -> [R4] {
        guard let i = intersection(a, b) else { return [a] }
        var out: [R4] = []
        if i[1] > a[1], let r = normalize(R4(a[0], a[1], a[2], i[1])) { out.append(r) }
        if i[3] < a[3], let r = normalize(R4(a[0], i[3], a[2], a[3])) { out.append(r) }
        if i[0] > a[0], let r = normalize(R4(a[0], i[1], i[0], i[3])) { out.append(r) }
        if i[2] < a[2], let r = normalize(R4(i[2], i[1], a[2], i[3])) { out.append(r) }
        return out
    }

    private static func cap(_ rects: [R4]) -> [R4] {
        Array(rects.prefix(maxClipRects))
    }

    private static func subtractAll(_ subject: [R4], _ cuts: [R4]) -> [R4] {
        var cur = subject
        for cut in cuts {
            var next: [R4] = []
            for s in cur {
                for piece in subtractOne(s, cut) {
                    if next.count >= maxClipRects { return next }
                    next.append(piece)
                }
            }
            cur = next
        }
        return cur
    }

    /// Intersects the current region with one rectangle.
    static func intersect(_ current: [R4]?, _ rect: R4) -> [R4]? {
        guard let rect = normalize(rect) else { return [] }
        guard let rects = current else { return [rect] }
        return cap(rects.compactMap { intersection($0, rect) })
    }

    /// Removes one rectangle. `surface` is the device bounds, used when the clip is still the default (the
    /// whole surface) so the remainder can be named.
    static func exclude(_ current: [R4]?, _ rect: R4, _ surface: R4?) -> [R4]? {
        guard let rect = normalize(rect) else { return current }
        if let rects = current { return subtractAll(rects, [rect]) }
        return surface.flatMap(normalize).map { subtractAll([$0], [rect]) }
    }

    /// Combines `incoming` with the current region in a region mode (`RGN_*`). An unknown mode leaves the region
    /// as it was. `RGN_COPY` replaces it. An `RGN_OR` or `RGN_XOR` against the default clip stays the default
    /// clip: the whole surface already covers the incoming rectangles.
    static func combine(_ current: [R4]?, _ incoming: [R4], _ mode: UInt32, _ surface: R4?) -> [R4]? {
        let incoming = cap(incoming.compactMap(normalize))
        switch mode {
        case rgnCopy:
            return incoming
        case rgnAnd:
            guard let rects = current else { return incoming }
            var out: [R4] = []
            for a in rects {
                for b in incoming {
                    if out.count >= maxClipRects { return out }
                    if let r = intersection(a, b) { out.append(r) }
                }
            }
            return out
        case rgnOr:
            guard let rects = current else { return nil }
            return cap(rects + incoming)
        case rgnDiff:
            if let rects = current { return subtractAll(rects, incoming) }
            return surface.flatMap(normalize).map { subtractAll([$0], incoming) }
        case rgnXor:
            guard let base = current else { return nil }
            var out = subtractAll(base, incoming)
            for r in subtractAll(incoming, base) {
                if out.count >= maxClipRects { break }
                out.append(r)
            }
            return out
        default:
            return current
        }
    }
}
