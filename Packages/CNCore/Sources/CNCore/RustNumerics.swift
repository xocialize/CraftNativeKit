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

    /// Rust's `f64::rem_euclid`: `self % rhs`, moved up by `|rhs|` when negative (it can round up to `|rhs|`).
    @inlinable
    public func remEuclid(_ rhs: Double) -> Double {
        let r = truncatingRemainder(dividingBy: rhs)
        return r < 0 ? r + abs(rhs) : r
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

    /// Rust's `%` on `f32` (C `fmodf`): the result has the sign of the dividend.
    @inlinable
    public func rem(_ divisor: Float) -> Float {
        truncatingRemainder(dividingBy: divisor)
    }

    /// Rust's `f32::rem_euclid`: `self % rhs`, moved up by `|rhs|` when negative. It can round up to
    /// `|rhs|` itself for tiny negative values, as Rust's does.
    @inlinable
    public func remEuclid(_ rhs: Float) -> Float {
        let r = truncatingRemainder(dividingBy: rhs)
        return r < 0 ? r + abs(rhs) : r
    }

    /// Rust's `f32::max` on Apple silicon (`fmaxnm`): a NaN operand is ignored, and +0 is above −0.
    @inlinable
    public func rustMax(_ other: Float) -> Float {
        if isNaN { return other }
        if other.isNaN { return self }
        if self == other { return sign == .minus ? other : self }
        return self > other ? self : other
    }

    /// Rust's `f32::min` on Apple silicon (`fminnm`): a NaN operand is ignored, and −0 is below +0.
    @inlinable
    public func rustMin(_ other: Float) -> Float {
        if isNaN { return other }
        if other.isNaN { return self }
        if self == other { return sign == .minus ? self : other }
        return self < other ? self : other
    }

    /// Rust's `f32::signum`: ±1 by the sign bit (so ±0 give ±1), NaN for NaN.
    @inlinable
    public var rustSignum: Float { isNaN ? .nan : (sign == .minus ? -1.0 : 1.0) }

    /// Rust's `f32::to_radians` (`self * (PI / 180.0)`, in `f32`).
    @inlinable
    public var toRadians: Float { self * (Float.pi / 180.0) }

    /// Rust's `f32::to_degrees`: `self` times 180/π rounded to `f32` once (not `180.0 / PI` in `f32`, which
    /// is an ulp off).
    @inlinable
    public var toDegrees: Float { self * 57.2957795130823208767981548141051703 }
}

extension Collection {
    /// Rust's `slice.get(i)`: nil instead of a trap when `i` is out of range.
    @inlinable
    public func at(_ i: Index) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
