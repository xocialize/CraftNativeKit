// CNCore — Rust's numeric semantics where Swift's differ, so ported arithmetic gives the same numbers
// and never traps. Swift's `UInt8(x)` traps on NaN or out-of-range values; Rust's `x as u8` saturates
// and maps NaN to 0. Ported code uses these wherever the Rust used `as`.

extension FixedWidthInteger {
    /// Rust's `value as Self` for a float: truncates toward zero, saturates at the bounds, NaN → 0.
    @inlinable
    public init(rustCast value: Double) {
        if value.isNaN {
            self = 0
        } else if value <= Double(Self.min) {
            self = Self.min
        } else if value >= Double(Self.max) {
            self = Self.max
        } else {
            self = Self(value.rounded(.towardZero))
        }
    }

    /// Rust's `value as Self` for an `f32`.
    @inlinable
    public init(rustCast value: Float) {
        self.init(rustCast: Double(value))
    }
}

extension Double {
    /// Rust's `f64::clamp`: `if x < min { min } else if x > max { max } else { x }`, so NaN and a −0
    /// within range pass through unchanged.
    @inlinable
    public func clamped(_ lo: Double, _ hi: Double) -> Double {
        var x = self
        if x < lo { x = lo }
        if x > hi { x = hi }
        return x
    }

    /// Rust's `%` on floats (C `fmod`): the result has the sign of the dividend.
    @inlinable
    public func rem(_ divisor: Double) -> Double {
        truncatingRemainder(dividingBy: divisor)
    }

    /// Rust's `f64::max` on Apple silicon (`fmaxnm`): a NaN operand is ignored, and +0 is above −0.
    @inlinable
    public func rustMax(_ other: Double) -> Double {
        if isNaN { return other }
        if other.isNaN { return self }
        if self == other { return sign == .minus ? other : self }
        return self > other ? self : other
    }

    /// Rust's `f64::min` on Apple silicon (`fminnm`): a NaN operand is ignored, and −0 is below +0.
    @inlinable
    public func rustMin(_ other: Double) -> Double {
        if isNaN { return other }
        if other.isNaN { return self }
        if self == other { return sign == .minus ? self : other }
        return self < other ? self : other
    }

    /// Rust's `f64::signum`: ±1 by the sign bit (so ±0 give ±1), NaN for NaN.
    @inlinable
    public var rustSignum: Double { isNaN ? .nan : (sign == .minus ? -1.0 : 1.0) }

    /// Rust's `f64::to_radians`.
    @inlinable
    public var toRadians: Double { self * (Double.pi / 180.0) }

    /// Rust's `f64::to_degrees`.
    @inlinable
    public var toDegrees: Double { self * (180.0 / Double.pi) }
}

extension Float {
    /// Rust's `f32::clamp`: NaN and a −0 within range pass through unchanged.
    @inlinable
    public func clamped(_ lo: Float, _ hi: Float) -> Float {
        var x = self
        if x < lo { x = lo }
        if x > hi { x = hi }
        return x
    }
}

extension Collection {
    /// Rust's `slice.get(i)`: nil instead of a trap when `i` is out of range.
    @inlinable
    public func at(_ i: Index) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
