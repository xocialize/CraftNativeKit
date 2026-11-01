// CNMetafile — path operations in `Double` and the shape builders that turn WMF/EMF rectangles, ellipses and
// arcs into cubic Béziers (the classic 4/3·tan(Δ/4) approximation, at most 90° per piece). Port of deckcraft
// crates/metafile/src/geom.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors), plus the
// Rust float semantics the port needs to give deckcraft's numbers bit for bit.
import CNCore
import Darwin

/// A point `(x, y)`.
struct P: Equatable, Hashable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    var isFinite: Bool { x.isFinite && y.isFinite }
}

enum Op: Equatable {
    case m(P)
    case l(P)
    case c(P, P, P)
    case z
}

/// Rust's `size_of::<Op>()`: three `(f64, f64)` and the discriminant, 8-byte aligned. Items cost this much
/// per path op against the byte budget, as in deckcraft.
let opSize = 56
/// Rust's `size_of::<[f64; 4]>()`.
let rect64Size = 32

// MARK: - Rust float semantics

/// `sin` and `cos` of one value from Darwin's `__sincos_stret`. Rust's release builds compute a sine and cosine
/// of the same value in one basic block with that call (LLVM merges the pair), and it rounds differently from
/// separate calls for a small share of inputs; calling it explicitly gives deckcraft's bits.
@inlinable
func sinCos(_ x: Double) -> (sin: Double, cos: Double) {
    let r = __sincos_stret(x)
    return (r.__sinval, r.__cosval)
}

/// Rust's `f64::rem_euclid`.
@inlinable
func remEuclid(_ v: Double, _ m: Double) -> Double {
    let r = v.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + Swift.abs(m) : r
}

/// Rust's `x as usize` (saturating, NaN → 0), as an `Int`.
@inlinable
func asUsize(_ x: Double) -> Int {
    Int(clamping: UInt64(rustCast: x))
}

/// Rust's float `sum()`: a fold from -0.0.
@inlinable
func rustSum(_ values: some Sequence<Double>) -> Double {
    values.reduce(-0.0, +)
}

@inlinable
func rustSum(_ values: some Sequence<Float>) -> Float {
    values.reduce(-0.0, +)
}

// MARK: - Shapes

func rect(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> [Op] {
    [.m(P(l, t)), .l(P(r, t)), .l(P(r, b)), .l(P(l, b)), .z]
}

/// Corner radii are half the EMF/WMF corner ellipse size, clamped so the corners never overlap.
func roundRect(_ l: Double, _ t: Double, _ r: Double, _ b: Double, _ ew: Double, _ eh: Double) -> [Op] {
    // Reversed corners (right < left, bottom < top) describe the same rectangle.
    let (l, r) = (l.rustMin(r), l.rustMax(r))
    let (t, b) = (t.rustMin(b), t.rustMax(b))
    let rx = Swift.abs(ew / 2.0).rustMin((r - l) / 2.0)
    let ry = Swift.abs(eh / 2.0).rustMin((b - t) / 2.0)
    let half = Double.pi / 2
    var ops: [Op] = [.m(P(l + rx, t)), .l(P(r - rx, t))]
    ops += arc(r - rx, t + ry, rx, ry, -half, half)
    ops.append(.l(P(r, b - ry)))
    ops += arc(r - rx, b - ry, rx, ry, 0.0, half)
    ops.append(.l(P(l + rx, b)))
    ops += arc(l + rx, b - ry, rx, ry, half, half)
    ops.append(.l(P(l, t + ry)))
    ops += arc(l + rx, t + ry, rx, ry, Double.pi, half)
    ops.append(.z)
    return ops
}

func ellipse(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> [Op] {
    let (cx, cy, rx, ry) = center(l, t, r, b)
    var ops: [Op] = [.m(P(cx + rx, cy))]
    ops += arc(cx, cy, rx, ry, 0.0, 2 * Double.pi)
    ops.append(.z)
    return ops
}

/// Which closed or open shape an ARC/CHORD/PIE record draws.
enum ArcKind {
    case arc, chord, pie
}

/// ARC, CHORD and PIE: the arc runs counter-clockwise on screen from the start point to the end point.
func arcShape(_ l: Double, _ t: Double, _ r: Double, _ b: Double, _ s: P, _ e: P, _ kind: ArcKind) -> [Op] {
    let (cx, cy, rx, ry) = center(l, t, r, b)
    func ang(_ p: P) -> Double {
        atan2((p.y - cy) / ry.rustMax(Double.leastNormalMagnitude), (p.x - cx) / rx.rustMax(Double.leastNormalMagnitude))
    }
    let (a0, a1) = (ang(s), ang(e))
    var d = remEuclid(a0 - a1, 2 * Double.pi)
    if d < 1e-12 { d = 2 * Double.pi }
    let sweep = -d
    let sc = sinCos(a0)
    let start = P(cx + rx * sc.cos, cy + ry * sc.sin)
    var ops: [Op] = kind == .pie ? [.m(P(cx, cy)), .l(start)] : [.m(start)]
    ops += arc(cx, cy, rx, ry, a0, sweep)
    switch kind {
    case .arc: break
    case .chord: ops.append(.z)
    case .pie: ops += [.l(P(cx, cy)), .z]
    }
    return ops
}

private func center(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> (Double, Double, Double, Double) {
    ((l + r) / 2.0, (t + b) / 2.0, Swift.abs(r - l) / 2.0, Swift.abs(b - t) / 2.0)
}

/// Cubic pieces along an ellipse from parameter `a0` over signed `sweep` radians. The current point must
/// already be at `(cx + rx cos a0, cy + ry sin a0)`.
private func arc(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ a0: Double, _ sweep: Double) -> [Op] {
    let n = Swift.min(Swift.max(asUsize((Swift.abs(sweep) / (Double.pi / 2)).rounded(.up)), 1), 8)
    let step = sweep / Double(n)
    let k = 4.0 / 3.0 * tan(step / 4.0)
    var ops: [Op] = []
    ops.reserveCapacity(n)
    for i in 0 ..< n {
        let t0 = a0 + step * Double(i)
        let t1 = t0 + step
        let s0 = sinCos(t0)
        let s1 = sinCos(t1)
        let p0 = P(cx + rx * s0.cos, cy + ry * s0.sin)
        let p3 = P(cx + rx * s1.cos, cy + ry * s1.sin)
        let c1 = P(p0.x - k * rx * s0.sin, p0.y + k * ry * s0.cos)
        let c2 = P(p3.x + k * rx * s1.sin, p3.y - k * ry * s1.cos)
        ops.append(.c(c1, c2, p3))
    }
    return ops
}

/// Consecutive subpaths: `counts[i]` points each, taken in order from `pts`. Counts that run past the point list
/// are cut short rather than failing the whole record.
func subpaths(_ pts: [P], _ counts: [Int], close: Bool) -> [Op] {
    var ops: [Op] = []
    ops.reserveCapacity(pts.count + counts.count)
    var at = 0
    for c in counts {
        let (sum, overflow) = at.addingReportingOverflow(c)
        let end = Swift.min(overflow ? Int.max : sum, pts.count)
        guard at < end else {
            at = end
            continue
        }
        ops.append(.m(pts[at]))
        for p in pts[(at + 1) ..< end] { ops.append(.l(p)) }
        if close { ops.append(.z) }
        at = end
    }
    return ops
}

extension Float {
    /// Rust's `f32::max` on Apple silicon (`fmaxnm`): a NaN operand is ignored, and +0 is above −0.
    func rustMax(_ other: Float) -> Float {
        Float(Double(self).rustMax(Double(other)))
    }

    /// Rust's `f32::min` on Apple silicon (`fminnm`): a NaN operand is ignored, and −0 is below +0.
    func rustMin(_ other: Float) -> Float {
        Float(Double(self).rustMin(Double(other)))
    }
}
