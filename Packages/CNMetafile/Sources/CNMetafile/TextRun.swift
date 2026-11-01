// CNMetafile — WordCraft's view of a text run: the reference point, a font size along the run's up direction and
// the baseline angle, with the layout of shaped glyphs against a font's metrics. deckcraft's reader already parses
// every record WordCraft's text commit (6931b8db) reads, and more, so the run is derived from a `MetafileText`
// instead of being parsed twice. Port of WordCraft crates/metafile/src/lib.rs (`Text`), place.rs (`Text::layout`,
// `PlacedItem::Text`) and canvas.rs (`Canvas::text` defaults) at fd7f6621 (MIT OR Apache-2.0, © ArtCraft Team and
// the WordCraft contributors).
import CNCore
import Darwin

/// Font height (cell height, text units) WordCraft gives a font of height 0.
private let defaultFontHeight: Double = 16
/// Face WordCraft uses when a font names none.
private let defaultFontFace = "Arial"

/// A text run in picture units, as WordCraft's renderers take it (`wordcraft_metafile::Text`).
public struct MetafileTextRun: Equatable, Sendable {
    public var text: String
    /// The reference point that `hAlign` and `vAlign` refer to.
    public var x: Float
    public var y: Float
    /// Font height: the em size, or the cell height (ascent + descent) when `cell` is set.
    public var size: Float
    public var cell: Bool
    public var font: String
    public var bold: Bool
    public var italic: Bool
    public var color: MetafileColor
    /// Baseline direction in radians, clockwise from +x (y down).
    public var angle: Float
    public var hAlign: MetafileHAlign
    public var vAlign: MetafileVAlign
    /// Advance of each character (Unicode scalar) along the baseline; empty when the font's own advances apply.
    public var dx: [Float]

    public init(
        text: String, x: Float, y: Float, size: Float, cell: Bool, font: String, bold: Bool, italic: Bool,
        color: MetafileColor, angle: Float, hAlign: MetafileHAlign, vAlign: MetafileVAlign, dx: [Float]
    ) {
        (self.text, self.x, self.y, self.size, self.cell, self.font) = (text, x, y, size, cell, font)
        (self.bold, self.italic, self.color, self.angle, self.hAlign, self.vAlign, self.dx) = (bold, italic, color, angle, hAlign, vAlign, dx)
    }

    public static func == (a: MetafileTextRun, b: MetafileTextRun) -> Bool {
        a.text.unicodeScalars.elementsEqual(b.text.unicodeScalars) && a.x == b.x && a.y == b.y && a.size == b.size
            && a.cell == b.cell && a.font.unicodeScalars.elementsEqual(b.font.unicodeScalars) && a.bold == b.bold
            && a.italic == b.italic && a.color == b.color && a.angle == b.angle && a.hAlign == b.hAlign
            && a.vAlign == b.vAlign && a.dx == b.dx
    }
}

/// A text run laid out with a font's metrics: the em size (in the run's own units, see
/// `MetafileTextRun.placement`), the baseline's y and each glyph's (x, y), alignment included.
public struct MetafileTextLayout: Equatable, Sendable {
    public var em: Double
    public var baseline: Double
    public var glyphs: [SIMD2<Double>]
}

extension MetafileText {
    /// The run as WordCraft draws it: the reference point and the baseline angle from `transform`, the size
    /// along the run's up direction (a font height of 0 is WordCraft's 16 text units), the advances along the
    /// baseline, the face (Arial when the font names none) and bold from a weight of 600 or more. Trailing NULs
    /// are dropped, as WordCraft drops them. nil when the reference point, the size or an advance is not finite,
    /// or the size is not positive.
    public var run: MetafileTextRun? {
        guard transform.count == 6 else { return nil }
        let m = transform
        // Picture units per text unit along the baseline and across it.
        let (along, across) = ((m[0] * m[0] + m[1] * m[1]).squareRoot(), (m[2] * m[2] + m[3] * m[3]).squareRoot())
        let height = font.height == 0 ? defaultFontHeight : Double(font.height)
        var scalars = Array(text.unicodeScalars)
        while scalars.last == "\0" { scalars.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        var dx: [Float] = []
        for d in self.dx.prefix(scalars.count) {
            let v = Float(Double(d) * along)
            guard v.isFinite else { return nil }
            dx.append(v)
        }
        let size = Float(height.magnitude * across)
        let (x, y) = (Float(m[4]), Float(m[5]))
        let angle = Float(atan2(m[1], m[0]))
        guard x.isFinite, y.isFinite, size.isFinite, size > 0 else { return nil }
        // The reader trims the face name already.
        let family = font.family
        return MetafileTextRun(
            text: String(out), x: x, y: y, size: size, cell: height > 0, font: family.isEmpty ? defaultFontFace : family,
            bold: font.weight >= 600, italic: font.italic, color: color, angle: angle.isFinite ? angle : 0,
            hAlign: hAlign, vAlign: vAlign, dx: dx
        )
    }
}

extension MetafileTextRun {
    /// The map from the run's own space (picture units, the reference point at the origin, the baseline along +x,
    /// y down) to the target, given the picture's `fit` transform: what WordCraft's `PlacedItem::Text` carries.
    /// nil when the reference point lands past ±1e6 target units (`place` leaves such items out).
    public func placement(_ fit: MetafileAffine) -> MetafileAffine? {
        let (x, y) = (Double(self.x), Double(self.y))
        let at = fit.apply(SIMD2(x, y))
        guard at.x.isFinite, at.y.isFinite, Swift.abs(at.x) < 1e6, Swift.abs(at.y) < 1e6 else { return nil }
        let (s, c) = sinCos(Double(angle))
        return fit * .translate(x, y) * MetafileAffine([c, s, -s, c, 0, 0])
    }

    /// Lays out shaped glyphs, given as (cluster, x advance, x offset, y offset) in font units of a font with `upem`
    /// units per em, `ascent` above and `descent` below the baseline. A cluster is the UTF-8 byte offset of the
    /// glyph's first character in `text`, as WordCraft's shaper gives it. The per-character advances `dx` place each
    /// cluster when there is one per character.
    public func layout(upem: Double, ascent: Double, descent: Double, glyphs: [(cluster: Int, advance: Double, xOffset: Double, yOffset: Double)]) -> MetafileTextLayout? {
        let upem = upem.isFinite && upem > 0 ? upem : 1000
        let cellHeight = ascent + descent
        let size = Double(self.size)
        let em = cell && cellHeight.isFinite && cellHeight > 0 ? size * upem / cellHeight : size
        guard em.isFinite, em > 0 else { return nil }
        let k = em / upem
        // The UTF-8 offset at which each character starts.
        var starts: [Int] = []
        var offset = 0
        for u in text.unicodeScalars {
            starts.append(offset)
            offset += UTF8.width(u)
        }
        var cum: [Double]?
        if dx.count == starts.count && !starts.isEmpty {
            var c: [Double] = [0]
            var x = 0.0
            for d in dx {
                x += Double(d)
                c.append(x)
            }
            cum = c
        }
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(glyphs.count)
        var (pen, clusterPen, last) = (0.0, 0.0, Int?.none)
        for g in glyphs {
            // The character the cluster starts in: the last start at or before it.
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= g.cluster { lo = mid + 1 } else { hi = mid }
            }
            let ci = Swift.max(lo - 1, 0)
            if last != ci {
                clusterPen = pen
                last = ci
            }
            let x = cum.map { ($0.at(ci) ?? 0) + pen - clusterPen } ?? pen
            out.append(SIMD2(x + g.xOffset * k, -g.yOffset * k))
            pen += g.advance * k
        }
        let width = cum?.last ?? pen
        let hoff: Double = switch hAlign {
        case .left: 0
        case .center: -width / 2
        case .right: -width
        }
        let baseline: Double = switch vAlign {
        case .top: ascent * k
        case .baseline: 0
        case .bottom: -descent * k
        }
        return MetafileTextLayout(em: em, baseline: baseline, glyphs: out.map { SIMD2($0.x + hoff, $0.y + baseline) })
    }
}
