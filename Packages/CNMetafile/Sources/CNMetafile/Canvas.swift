// CNMetafile — drawing state shared by the WMF and EMF readers: window/viewport mapping and the EMF world transform,
// pen and brush selection through an object table, the DC save stack and path brackets. Output is device-space
// items; `Metafile.build` maps them into the picture frame. Port of deckcraft crates/metafile/src/canvas.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The object table's free-slot set and the in-place
// mapping of shape ops are from WordCraft crates/metafile/src/canvas.rs at fd7f6621 (MIT OR Apache-2.0, © ArtCraft
// Team and the WordCraft contributors) (45d2546b).
import CNCore
import Darwin

let mmText: UInt32 = 1
private let mmIsotropic: UInt32 = 7
private let mmAnisotropic: UInt32 = 8
private let stock: UInt32 = 0x8000_0000
let psNull: UInt32 = 5
/// Pen style bits; the rest of the style word holds end-cap, join and type flags.
let psStyleMask: UInt32 = 0x0F
let bsSolid: UInt32 = 0
/// Cells on the longer side of a computed (gradient or texture) fill tile.
private let shadeRes = 128
let bsNull: UInt32 = 1
let bsHatched: UInt32 = 2
/// BS_PATTERN, BS_DIBPATTERN and BS_DIBPATTERNPT: the brush paints a bitmap tile.
private let bsPattern: UInt32 = 3
private let bsDIBPattern: UInt32 = 5
private let bsDIBPatternPT: UInt32 = 6
private let winding: UInt32 = 2
/// SETROP2 mix modes. R2_NOP leaves the destination alone: outlines and fills draw nothing. R2_XORPEN and
/// R2_MASKPEN draw the classic see-through shadow (XOR a colour, AND a pattern, XOR the colour again); the
/// others draw as R2_COPYPEN.
private let r2XorPen: UInt32 = 7
private let r2MaskPen: UInt32 = 9
private let r2Nop: UInt32 = 11
private let r2CopyPen: UInt32 = 13
/// SETBKMODE OPAQUE: text cells and hatch gaps are filled with the background colour.
private let opaque: UInt32 = 2
private let patCopy: UInt32 = 0x00F0_0021
private let blackness: UInt32 = 0x0000_0042
private let whiteness: UInt32 = 0x00FF_0062
/// Device pixels per millimetre assumed for WMF (96 dpi), and for EMF files without a device size.
private let defaultPxPerMM = 96.0 / 25.4
/// Rust's `size_of::<[f64; 4]>()`, `size_of::<Op>()`: the byte budget counts what deckcraft's items hold.
private let regionRectSize = rect64Size

/// Affine transform `[m11, m12, m21, m22, dx, dy]` in EMF XFORM order: `x' = x·m11 + y·m21 + dx`.
typealias Xform = [Double]
let identityXform: Xform = [1, 0, 0, 1, 0, 0]

/// `a` then `b` in EMF row-vector convention: the matrix product `a × b`.
func mul(_ a: Xform, _ b: Xform) -> Xform {
    [
        a[0] * b[0] + a[1] * b[2],
        a[0] * b[1] + a[1] * b[3],
        a[2] * b[0] + a[3] * b[2],
        a[2] * b[1] + a[3] * b[3],
        a[4] * b[0] + a[5] * b[2] + b[4],
        a[4] * b[1] + a[5] * b[3] + b[5],
    ]
}

struct Pen: Equatable {
    var style: UInt32
    /// Logical width; 0 means a cosmetic one-pixel hairline.
    var width: Double
    var color: MetafileColor
}

struct Brush: Equatable {
    var style: UInt32
    var color: MetafileColor
    /// HS_* hatch style of a BS_HATCHED brush.
    var hatch: UInt32 = 0
    /// The tile of a pattern brush.
    var pattern: Pattern?

    init(_ style: UInt32, _ color: MetafileColor) {
        self.style = style
        self.color = color
    }

    /// A pattern brush painting `img`. A monochrome brush paints its dark pixels in the text colour and its light
    /// ones in the background colour. nil for an empty or oversized tile.
    static func pattern(_ img: Rgba, mono: Bool) -> Brush? {
        if img.w == 0 || img.h == 0 || img.w > maxTileSide || img.h > maxTileSide || img.px.count != img.w * img.h * 4 {
            return nil
        }
        var b = Brush(bsDIBPatternPT, MetafileColor(0, 0, 0, 255))
        b.pattern = Pattern(w: img.w, h: img.h, px: img.px, mono: mono)
        return b
    }
}

/// A pattern brush's tile, top-down RGBA. A class, so every copy of the brush shares the tile it draws.
final class Pattern: Equatable {
    let w: Int
    let h: Int
    let px: [UInt8]
    let mono: Bool
    /// The tile as drawn when nothing recolours it, shared by every fill with this brush.
    var plain: RawTile?

    init(w: Int, h: Int, px: [UInt8], mono: Bool) {
        self.w = w
        self.h = h
        self.px = px
        self.mono = mono
    }

    static func == (a: Pattern, b: Pattern) -> Bool {
        a.w == b.w && a.h == b.h && a.px == b.px && a.mono == b.mono && a.plain == b.plain
    }
}

/// Largest pattern tile side kept (GDI brushes are typically 8×8).
let maxTileSide = 256

enum Obj {
    case pen(Pen)
    case brush(Brush)
    case font(LogFont)
    /// Palettes and regions: they take a table slot but draw nothing.
    case other
}

/// A font object: the neutral `MetafileFont` and its escapement (tenths of a degree, counter-clockwise), which
/// the text transform takes.
struct LogFont: Equatable {
    var font = MetafileFont()
    var escapement: Double = 0
}

/// A brush tile in device units: `cell` device units per tile pixel, laid from the device origin. A class: fills
/// with the same brush share one tile, and `Metafile.build` keeps them shared.
final class RawTile: Equatable {
    let w: Int
    let h: Int
    let px: [UInt8]
    let cell: Double
    /// Whether something besides the drawn item holds the tile (a brush's cached tile): its pixels are counted
    /// against the byte budget once, not per fill (deckcraft checks `Arc::strong_count`).
    var held = false

    init(w: Int, h: Int, px: [UInt8], cell: Double) {
        self.w = w
        self.h = h
        self.px = px
        self.cell = cell
    }

    static func == (a: RawTile, b: RawTile) -> Bool {
        a.w == b.w && a.h == b.h && a.px == b.px && a.cell == b.cell
    }
}

/// What a fill paints.
private enum Paint {
    case solid(MetafileColor)
    case tile(RawTile)
}

/// Converts a COLORREF (0x00BBGGRR) to opaque RGBA.
func colorref(_ c: UInt32) -> MetafileColor {
    MetafileColor(UInt8(truncatingIfNeeded: c), UInt8(truncatingIfNeeded: c >> 8), UInt8(truncatingIfNeeded: c >> 16), 255)
}

/// Millimetres per logical unit of the metric map modes (LOMETRIC, HIMETRIC, LOENGLISH, HIENGLISH, TWIPS).
private func metricMM(_ mode: UInt32) -> Double? {
    switch mode {
    case 2: 0.1
    case 3: 0.01
    case 4: 25.4 / 100.0
    case 5: 25.4 / 1000.0
    case 6: 25.4 / 1440.0
    default: nil
    }
}

struct Mapping {
    var wo = P(0, 0)
    var we = P(1, 1)
    var vo = P(0, 0)
    var ve = P(1, 1)
    var mode = mmText
    var world = identityXform
    /// Device pixels per millimetre on each axis (EMF: from szlDevice and szlMillimeters).
    var pxMM = P(defaultPxPerMM, defaultPxPerMM)

    /// Logical point to device point: world transform, then window to viewport.
    func device(_ p: P) -> P {
        let w = world
        let (x, y) = (p.x * w[0] + p.y * w[2] + w[4], p.x * w[1] + p.y * w[3] + w[5])
        let (sx, sy) = ratios()
        return P((x - wo.x) * sx + vo.x, (y - wo.y) * sy + vo.y)
    }

    /// Window-to-viewport scale per axis. MM_TEXT fixes the scale at 1; the metric modes use a fixed scale with
    /// y up; MM_ISOTROPIC uses one scale on both axes (the smaller magnitude, each axis's sign kept); anisotropic
    /// and unknown modes use the extents as given.
    private func ratios() -> (Double, Double) {
        if mode == mmText { return (1, 1) }
        if let mm = metricMM(mode) { return (mm * pxMM.x, -mm * pxMM.y) }
        let (rx, ry) = (ratio(ve.x, we.x), ratio(ve.y, we.y))
        if mode == mmIsotropic {
            let s = Swift.abs(rx).rustMin(Swift.abs(ry))
            return (rx < 0 ? -s : s, ry < 0 ? -s : s)
        }
        return (rx, ry)
    }

    /// Approximate device length per logical length, for pen widths.
    fileprivate func scale() -> Double {
        let w = world
        let det = Swift.abs(w[0] * w[3] - w[1] * w[2]).squareRoot()
        let (sx, sy) = ratios()
        return det * (Swift.abs(sx) + Swift.abs(sy)) / 2
    }

    /// True when the window-to-viewport extents set the scale (the isotropic and anisotropic modes).
    var usesExtents: Bool { mode == mmIsotropic || mode == mmAnisotropic }

    var windowExt: P { we }
    var viewportExt: P { ve }

    /// The window in device units as `[x, y, w, h]` with positive extents, used as the picture frame of a plain
    /// WMF.
    var windowRect: R4 {
        let a = device(wo)
        let b = device(P(wo.x + we.x, wo.y + we.y))
        return R4(a.x.rustMin(b.x), a.y.rustMin(b.y), Swift.abs(b.x - a.x), Swift.abs(b.y - a.y))
    }
}

private func ratio(_ num: Double, _ den: Double) -> Double {
    den == 0 ? 1 : num / den
}

/// Output of drawing, in device units. Path points are already mapped; `Metafile.build` normalises them.
enum Raw {
    /// `region` is the device-space clip region; nil is the default clip.
    case path(ops: [Op], fill: MetafileColor?, stroke: (MetafileColor, Double)?, evenOdd: Bool, region: [R4]?)
    /// A path filled with a repeating tile.
    case pattern(ops: [Op], evenOdd: Bool, tile: RawTile, region: [R4]?)
    case bitmap(rect: R4, img: Rgba, region: [R4]?)
    /// Text whose transform and clip are in device units.
    case text(MetafileText, region: [R4]?)

    fileprivate func withRegion(_ region: [R4]?) -> Raw {
        switch self {
        case .path(let ops, let fill, let stroke, let evenOdd, _): .path(ops: ops, fill: fill, stroke: stroke, evenOdd: evenOdd, region: region)
        case .pattern(let ops, let evenOdd, let tile, _): .pattern(ops: ops, evenOdd: evenOdd, tile: tile, region: region)
        case .bitmap(let rect, let img, _): .bitmap(rect: rect, img: img, region: region)
        case .text(let t, _): .text(t, region: region)
        }
    }
}

/// Text drawing state: colours, background mode, alignment and the selected font.
private struct TextState {
    var color: MetafileColor
    var bkColor: MetafileColor
    var bkOpaque: Bool
    var align: UInt32
    var font: LogFont?
}

private struct Saved {
    var map: Mapping
    var pen: Pen
    var brush: Brush
    var evenOdd: Bool
    var rop2: UInt32
    var text: TextState
    var clip: [R4]?
}

struct Canvas {
    var items: [Raw] = []
    var map = Mapping()
    /// True once SETWINDOWEXT was seen, so a plain WMF has a frame to use.
    var windowSet = false
    /// True once the file set the viewport extent itself (not the player, see `playInto`).
    var viewportSet = false
    private var saved: [Saved] = []
    /// Bytes held by the items so far (path ops and pixels), capped at `Metafile.maxBytes`.
    private var used = 0
    private(set) var objects: [Obj?] = []
    /// Indices below `objects.count` that hold no object, so the WMF handle table finds its lowest free slot
    /// without scanning.
    private var free = SlotSet()
    /// Free slots handed out by `addObject(nil, …)`; the tests check it grows by one per create that reuses a slot.
    private(set) var slotProbes = 0
    private var pen = Pen(style: 0, width: 0, color: MetafileColor(0, 0, 0, 255))
    private var brush = Brush(bsSolid, MetafileColor(255, 255, 255, 255))
    private var evenOdd = true
    /// SETROP2 mix mode.
    private var rop2 = r2CopyPen
    /// The colour of the last fill drawn with R2_XORPEN, for the see-through shadow idiom.
    private var xorColor: MetafileColor?
    private var ts = TextState(
        color: MetafileColor(0, 0, 0, 255), bkColor: MetafileColor(255, 255, 255, 255), bkOpaque: true, align: 0, font: nil
    )
    /// Device units per pattern-brush pixel: brushes are laid out in 96-dpi pixels.
    var patternPx: Double = 1
    private var pos = P(0, 0)
    private var inPath = false
    private var path: [Op] = []
    private(set) var full = false
    /// Current clip in device units. nil is the default (the whole surface); `[]` draws nothing.
    private var clip: [R4]?
    /// Device bounds of the picture, so excluding from the default clip has a surface to cut.
    private var surface: R4?
    /// EMF+ convex device clip polygon: drawing is cut to it geometrically.
    private var plusClip: [P]?

    init() {}

    /// Device bounds `[x0, y0, x1, y1]` of the picture. Used when a clip record cuts the default clip.
    mutating func setClipSurface(_ rect: R4) {
        surface = Clip.normalize(rect)
    }

    private mutating func push(_ raw: Raw) {
        guard let c = plusClip else { return pushRaw(raw) }
        for r in ClipRect.clipRaw(raw, c) { pushRaw(r) }
    }

    private mutating func pushRaw(_ raw: Raw) {
        if let c = clip, c.isEmpty { return }
        let raw = raw.withRegion(clip)
        let regionCost = (clip?.count ?? 0) * regionRectSize
        let cost: Int = switch raw {
        case .path(let ops, _, _, _, _): ops.count * opSize
        // A tile shared with its brush is counted once (by the brush); one made for this fill counts here.
        case .pattern(let ops, _, let tile, _): ops.count * opSize + 64 + (tile.held ? 0 : tile.px.count)
        case .bitmap(_, let img, _): img.px.count
        case .text(let t, _): t.text.utf8.count + t.dx.count * 4 + t.font.family.utf8.count + 128
        }
        let total = cost + regionCost
        let (next, overflow) = used.addingReportingOverflow(total)
        if items.count >= Metafile.maxItems || overflow || next > Metafile.maxBytes {
            full = true
        } else {
            used = next
            items.append(raw)
        }
    }

    mutating func setWindowOrg(_ p: P) { map.wo = p }

    mutating func setWindowExt(_ e: P) {
        map.we = e
        windowSet = true
    }

    mutating func setViewportOrg(_ p: P) { map.vo = p }

    mutating func setViewportExt(_ e: P) {
        map.ve = e
        viewportSet = true
    }

    /// Sets up the mapping the way a player does before it plays a WMF into a target: anisotropic, `window`
    /// (`[x, y, w, h]` in logical units) onto a viewport of `size` at the origin. The file's own window records
    /// then replace the window; the viewport stays unless the file sets one. Without a window (a plain WMF) only
    /// the viewport extent is set: the map mode and viewport origin stay the file's.
    mutating func playInto(_ window: R4?, _ size: P) {
        if let w = window {
            map.mode = mmAnisotropic
            map.wo = P(w[0], w[1])
            map.we = P(w[2], w[3])
            map.vo = P(0, 0)
        }
        map.ve = size
    }

    mutating func setMapMode(_ mode: UInt32) { map.mode = mode }

    /// Device pixels per millimetre (x, y) for the metric map modes. Ignored unless both are positive.
    mutating func setDeviceMM(_ pxMM: P) {
        if pxMM.isFinite && pxMM.x > 0 && pxMM.y > 0 { map.pxMM = pxMM }
    }

    mutating func setPolyfill(_ mode: UInt32) { evenOdd = mode != winding }

    /// SETROP2. R2_NOP draws nothing; R2_XORPEN and R2_MASKPEN are read as the see-through shadow idiom (see
    /// `fillPaint`); the other mix modes draw as copy.
    mutating func setRop2(_ mode: UInt32) { rop2 = mode }

    mutating func setTextColor(_ c: UInt32) { ts.color = colorref(c) }

    mutating func setBkColor(_ c: UInt32) { ts.bkColor = colorref(c) }

    mutating func setBkMode(_ mode: UInt32) { ts.bkOpaque = mode == opaque }

    mutating func setTextAlign(_ ta: UInt32) { ts.align = ta }

    /// The character set of the selected font (ANSI without one).
    var fontCharset: UInt8 { ts.font?.font.charset ?? 0 }

    /// EMF SETWORLDTRANSFORM (`mode` 4) and MODIFYWORLDTRANSFORM (1 identity, 2 left, 3 right, 4 set). An unknown
    /// mode leaves the world transform as it was.
    mutating func modifyWorld(_ x: Xform, _ mode: UInt32) {
        switch mode {
        case 1: map.world = identityXform
        case 2: map.world = mul(x, map.world)
        case 3: map.world = mul(map.world, x)
        case 4: map.world = x
        default: break
        }
    }

    /// The current world transform (EMF+ draws through it).
    var world: Xform { map.world }

    /// Sets the pen and brush directly (EMF+ records name their own pen and brush).
    mutating func setPen(_ pen: Pen) { self.pen = pen }

    mutating func setBrush(_ brush: Brush) { self.brush = brush }

    /// Sets the EMF+ convex device clip polygon (nil: unclipped).
    mutating func setClip(_ clip: [P]?) { plusClip = clip }

    /// Logical to device as one affine transform (the mapping is affine).
    var deviceAffine: Xform {
        let o = map.device(P(0, 0))
        let x = map.device(P(1, 0))
        let y = map.device(P(0, 1))
        return [x.x - o.x, x.y - o.y, y.x - o.x, y.y - o.y, o.x, o.y]
    }

    /// Text colour, font and alignment set directly (EMF+ strings name their own font and brush); the background
    /// is transparent.
    mutating func setTextStyle(_ color: MetafileColor, _ font: LogFont, _ align: UInt32) {
        ts.color = color
        ts.bkOpaque = false
        ts.align = align
        ts.font = font
    }

    /// Pushes an item already in device units (a nested metafile's drawing).
    mutating func pushDevice(_ raw: Raw) { push(raw) }

    /// Fills logical `ops` with a ready-made tile, laid from the device origin.
    mutating func tileShape(_ ops: [Op], _ tile: RawTile) {
        let dev = ops.map { mapOp($0) }
        if dev.count >= 2 { push(.pattern(ops: dev, evenOdd: evenOdd, tile: tile, region: nil)) }
    }

    /// Fills logical `ops` with a colour computed per device point (gradients, textures): a tile of at most
    /// `shadeRes` cells on the longer side, laid out so that its one repeat covers the shape.
    mutating func shadeShape(_ ops: [Op], _ shade: (P) -> MetafileColor) {
        let dev = ops.map { mapOp($0) }
        guard let bb = ClipRect.opsBBox(dev) else { return }
        let (l, t, r, b) = (bb[0], bb[1], bb[2], bb[3])
        let side = (r - l).rustMax(b - t)
        guard dev.count >= 2, side.isFinite, side > 0 else { return }
        let cell = side / Double(shadeRes)
        let w = Swift.min(Swift.max(asUsize(((r - l) / cell).rounded(.up)).addingSaturating(1), 1), shadeRes + 1)
        let h = Swift.min(Swift.max(asUsize(((b - t) / cell).rounded(.up)).addingSaturating(1), 1), shadeRes + 1)
        let (pw, ph) = (Double(w) * cell, Double(h) * cell)
        var px: [UInt8] = []
        px.reserveCapacity(w * h * 4)
        for j in 0 ..< h {
            // The device position this tile row stands for inside the shape's box.
            let y = t + remEuclid(Double(j) * cell - t, ph) + cell / 2
            for i in 0 ..< w {
                let x = l + remEuclid(Double(i) * cell - l, pw) + cell / 2
                let c = shade(P(x, y))
                px += [c[0], c[1], c[2], c[3]]
            }
        }
        push(.pattern(ops: dev, evenOdd: evenOdd, tile: RawTile(w: w, h: h, px: px, cell: cell), region: nil))
    }

    /// Pushes the drawing state. Past `Metafile.maxStack` levels the parse stops, since later restores could no
    /// longer match the file.
    mutating func saveDC() {
        if saved.count < Metafile.maxStack {
            saved.append(Saved(map: map, pen: pen, brush: brush, evenOdd: evenOdd, rop2: rop2, text: ts, clip: clip))
        } else {
            full = true
        }
    }

    /// Negative `n` pops `-n` levels; positive `n` restores absolute level `n`.
    mutating func restoreDC(_ n: Int32) {
        let idx: Int = n < 0 ? saved.count - Int(n.magnitude) : Int(n) - 1
        guard idx >= 0, let s = saved.at(idx) else { return }
        saved.removeSubrange(idx...)
        map = s.map
        pen = s.pen
        brush = s.brush
        evenOdd = s.evenOdd
        rop2 = s.rop2
        ts = s.text
        clip = s.clip
    }

    /// The logical rectangle as a device rectangle. A scale or translation keeps the rectangle; a rotation stores
    /// the bounds of the rotated corners.
    private func deviceRect(_ r: R4) -> R4? {
        let (l, t, rr, b) = (r[0], r[1], r[2], r[3])
        let corners = [P(l, t), P(rr, t), P(l, b), P(rr, b)].map(map.device)
        guard corners.allSatisfy(\.isFinite) else { return nil }
        var (x0, y0, x1, y1) = (Double.infinity, Double.infinity, -Double.infinity, -Double.infinity)
        for p in corners {
            x0 = x0.rustMin(p.x)
            y0 = y0.rustMin(p.y)
            x1 = x1.rustMax(p.x)
            y1 = y1.rustMax(p.y)
        }
        return Clip.normalize(R4(x0, y0, x1, y1))
    }

    private func mapRects(_ logical: [R4]) -> [R4] {
        var out: [R4] = []
        for r in logical.prefix(Clip.maxClipRects) {
            if let d = deviceRect(r) { out.append(d) }
            if out.count >= Clip.maxClipRects { break }
        }
        return out
    }

    /// INTERSECTCLIPRECT: later drawing is limited to this logical rectangle as well.
    mutating func intersectClipRect(_ logical: R4) {
        clip = deviceRect(logical).map { Clip.intersect(clip, $0) } ?? []
    }

    /// EXCLUDECLIPRECT: this logical rectangle is removed from the clip.
    mutating func excludeClipRect(_ logical: R4) {
        guard let rect = deviceRect(logical) else { return }
        clip = Clip.exclude(clip, rect, surface)
    }

    /// EXTSELECTCLIPRGN: combine these logical rectangles with the clip in a `RGN_*` mode.
    mutating func selectClipRects(_ logical: [R4], _ mode: UInt32) {
        clip = Clip.combine(clip, mapRects(logical), mode, surface)
    }

    /// The default clip: later records are not limited by a region.
    mutating func resetClip() { clip = nil }

    /// Stores an object in `slot` (EMF index), or in the lowest free slot (WMF handle table).
    mutating func addObject(_ slot: Int?, _ obj: Obj) {
        // A pattern brush's pixels count against the byte budget like drawn items.
        if case .brush(let b) = obj, let p = b.pattern {
            let (next, overflow) = used.addingReportingOverflow(p.px.count)
            if overflow || next > Metafile.maxBytes {
                full = true
                return
            }
            used = next
        }
        if let i = slot {
            guard i >= 0, i < Metafile.maxObjects else { return }
            if objects.count <= i {
                // Growing the table leaves the slots between the old end and `i` free.
                for k in objects.count ..< i { free.insert(k) }
                objects += [Obj?](repeating: nil, count: i + 1 - objects.count)
            }
            free.remove(i)
            objects[i] = obj
        } else if let i = free.popFirst(), objects.indices.contains(i) {
            slotProbes += 1
            objects[i] = obj
        } else if objects.count < Metafile.maxObjects {
            objects.append(obj)
        }
    }

    mutating func deleteObject(_ i: UInt32) {
        let k = Int(i)
        if objects.indices.contains(k) {
            objects[k] = nil
            free.insert(k)
        }
    }

    /// Selects an object by index; indices with the high bit set are stock objects.
    mutating func select(_ i: UInt32) {
        if i & stock != 0 { return selectStock(i & ~stock) }
        switch objects.at(Int(i)) ?? nil {
        case .pen(let p): pen = p
        case .brush(let b): brush = b
        case .font(let f): ts.font = f
        case .other, nil: break
        }
    }

    private mutating func selectStock(_ i: UInt32) {
        let white = MetafileColor(255, 255, 255, 255)
        let black = MetafileColor(0, 0, 0, 255)
        func gray(_ v: UInt8) -> Brush { Brush(bsSolid, MetafileColor(v, v, v, 255)) }
        switch i {
        case 0, 18: brush = Brush(bsSolid, white)
        case 1: brush = gray(192)
        case 2: brush = gray(128)
        case 3: brush = gray(64)
        case 4: brush = Brush(bsSolid, black)
        case 5: brush = Brush(bsNull, black)
        case 6: pen = Pen(style: 0, width: 0, color: white)
        case 7, 19: pen = Pen(style: 0, width: 0, color: black)
        case 8: pen = Pen(style: psNull, width: 0, color: black)
        // The stock fonts (OEM_FIXED_FONT … DEFAULT_GUI_FONT): drawn in the default face.
        case 10 ... 17: ts.font = nil
        default: break
        }
    }

    private func mapOp(_ op: Op) -> Op {
        switch op {
        case .m(let p): .m(map.device(p))
        case .l(let p): .l(map.device(p))
        case .c(let a, let b, let c): .c(map.device(a), map.device(b), map.device(c))
        case .z: .z
        }
    }

    /// The current brush's paint. Hatch and monochrome brushes take the background colour (when the background
    /// mode is opaque) and the text colour. Under R2_MASKPEN (destination AND brush) a tile's white pixels keep
    /// what is below, and its black ones take the colour of the XOR fill before it: XOR, AND, XOR again leaves
    /// that colour where the tile is black.
    private func fillPaint() -> Paint? {
        let b = brush
        switch b.style {
        case bsSolid:
            return .solid(b.color)
        case bsHatched:
            let bg = ts.bkOpaque ? ts.bkColor : nil
            guard let px = hatchTile(b.hatch, b.color, bg) else { return nil }
            return .tile(RawTile(w: 8, h: 8, px: px, cell: patternPx))
        case bsPattern, bsDIBPattern, bsDIBPatternPT:
            guard let p = b.pattern else { return nil }
            if !p.mono && rop2 != r2MaskPen {
                if let t = p.plain { return .tile(t) }
                let t = RawTile(w: p.w, h: p.h, px: p.px, cell: patternPx)
                t.held = true
                p.plain = t
                return .tile(t)
            }
            var px = p.px
            var k = 0
            while k + 4 <= px.count {
                if p.mono {
                    let light = UInt16(px[k]) + UInt16(px[k + 1]) + UInt16(px[k + 2]) >= 384
                    let v = light ? ts.bkColor : ts.color
                    (px[k], px[k + 1], px[k + 2], px[k + 3]) = (v[0], v[1], v[2], 255)
                }
                if rop2 == r2MaskPen {
                    if px[k] == 255 && px[k + 1] == 255 && px[k + 2] == 255 {
                        px[k + 3] = 0
                    } else if px[k] == 0 && px[k + 1] == 0 && px[k + 2] == 0, let x = xorColor {
                        (px[k], px[k + 1], px[k + 2], px[k + 3]) = (x[0], x[1], x[2], x[3])
                    }
                }
                k += 4
            }
            return .tile(RawTile(w: p.w, h: p.h, px: px, cell: patternPx))
        default:
            return nil
        }
    }

    /// Pushes device ops filled with `fill` and stroked with `stroke`: a tile fill and its outline are two items.
    private mutating func pushShape(_ ops: [Op], _ fill: Paint?, _ stroke: (MetafileColor, Double)?) {
        switch fill {
        case .tile(let tile):
            push(.pattern(ops: ops, evenOdd: evenOdd, tile: tile, region: nil))
            if stroke != nil { push(.path(ops: ops, fill: nil, stroke: stroke, evenOdd: evenOdd, region: nil)) }
        case .solid(let c):
            push(.path(ops: ops, fill: c, stroke: stroke, evenOdd: evenOdd, region: nil))
        case nil:
            if stroke != nil { push(.path(ops: ops, fill: nil, stroke: stroke, evenOdd: evenOdd, region: nil)) }
        }
    }

    /// Whether the mix mode suppresses drawing: R2_NOP draws nothing, and R2_XORPEN shapes only remember their
    /// fill colour (an XOR pair cancels; the see-through shadow idiom draws its pattern in that colour).
    private mutating func mixSkips(_ fill: Bool) -> Bool {
        switch rop2 {
        case r2Nop:
            return true
        case r2XorPen:
            if fill && brush.style == bsSolid { xorColor = brush.color }
            return true
        default:
            return false
        }
    }

    private func strokePen() -> (MetafileColor, Double)? {
        if pen.style & psStyleMask == psNull { return nil }
        // A cosmetic pen (width 0) stays 0: the renderers draw that as a hairline.
        let w = pen.width == 0 ? 0 : Swift.abs(pen.width) * map.scale()
        return (pen.color, w)
    }

    private mutating func pushPathOps(_ ops: [Op]) {
        for op in ops {
            if path.count >= Metafile.maxPathOps { return }
            path.append(op)
        }
    }

    /// Draws logical-space ops with the current pen (`stroke`) and brush (`fill`), or appends them to the open path
    /// bracket, where fill and stroke wait for FILLPATH/STROKEPATH.
    mutating func shape(_ ops: consuming [Op], fill: Bool, stroke: Bool) {
        // Maps in place: the caller's array becomes the device-space path, no second copy.
        var dev = ops
        for i in dev.indices { dev[i] = mapOp(dev[i]) }
        if inPath { return pushPathOps(dev) }
        if mixSkips(fill) || dev.count < 2 { return }
        let paint = fill ? fillPaint() : nil
        let pen = stroke ? strokePen() : nil
        pushShape(dev, paint, pen)
    }

    mutating func moveTo(_ p: P) {
        if inPath { pushPathOps([.m(map.device(p))]) }
        pos = p
    }

    /// LINETO from the current point, then moves the current point to `p`.
    mutating func lineTo(_ p: P) {
        lineChain([p], fill: false, stroke: true)
    }

    /// Lines from the current point through `pts` (POLYLINETO), or a polyline from the current point.
    mutating func lineChain(_ pts: [P], fill: Bool, stroke: Bool) {
        // Inside an open bracket the path already ends at the current point, so no MoveTo is needed.
        var ops: [Op] = inPath && !path.isEmpty ? [] : [.m(pos)]
        ops += pts.map { .l($0) }
        if let last = pts.last { pos = last }
        shape(ops, fill: fill, stroke: stroke)
    }

    /// POLYBEZIER: cubic segments that start a new figure at `from`. The current point is unchanged.
    mutating func bezier(_ from: P, _ pts: [P]) {
        shape([.m(from)] + cubics(pts), fill: false, stroke: true)
    }

    /// POLYBEZIERTO: cubic segments from the current point through groups of three control or end points; the
    /// current point moves to the last point. Inside an open bracket the path already ends at the current point,
    /// so no MoveTo is needed.
    mutating func bezierTo(_ pts: [P]) {
        var ops: [Op] = inPath && !path.isEmpty ? [] : [.m(pos)]
        ops += cubics(pts)
        if let last = pts.last { pos = last }
        shape(ops, fill: false, stroke: true)
    }

    mutating func poly(_ pts: [P], close: Bool, fill: Bool, stroke: Bool) {
        guard let first = pts.first else { return }
        var ops: [Op] = [.m(first)]
        ops += pts.dropFirst().map { .l($0) }
        if close { ops.append(.z) }
        shape(ops, fill: fill, stroke: stroke)
    }

    mutating func beginPath() {
        inPath = true
        path.removeAll()
    }

    mutating func endPath() { inPath = false }

    mutating func closeFigure() {
        if inPath { pushPathOps([.z]) }
    }

    /// FILLPATH, STROKEPATH and STROKEANDFILLPATH: paints the bracketed path and empties it.
    mutating func paintPath(fill: Bool, stroke: Bool) {
        let ops = path
        path = []
        if mixSkips(fill) || ops.count < 2 { return }
        let paint = fill ? fillPaint() : nil
        let pen = stroke ? strokePen() : nil
        pushShape(ops, paint, pen)
    }

    /// Fills a logical rectangle `[l, t, r, b]` with the current brush (PATBLT, PATCOPY blits).
    mutating func fillBrushRect(_ r: R4) {
        if mixSkips(true) { return }
        let paint = fillPaint()
        pushShape(rect(r[0], r[1], r[2], r[3]).map { mapOp($0) }, paint, nil)
    }

    /// Fills a logical rectangle `[l, t, r, b]` with a solid colour (ROP fills such as BLACKNESS).
    mutating func fillRectWith(_ r: R4, _ color: MetafileColor) {
        push(.path(ops: rect(r[0], r[1], r[2], r[3]).map { mapOp($0) }, fill: color, stroke: nil, evenOdd: true, region: nil))
    }

    /// Whether a raster operation draws without a source bitmap (PATCOPY, BLACKNESS, WHITENESS).
    static func sourceless(_ rop: UInt32) -> Bool {
        rop == patCopy || rop == blackness || rop == whiteness
    }

    /// Fills a logical rectangle `[x, y, w, h]` for a source-less raster operation. PATCOPY uses the brush (when
    /// solid); the others fill black or white. Other operations are not handled here.
    mutating func fillRop(_ r: R4, _ rop: UInt32) {
        let rect = R4(r[0], r[1], r[0] + r[2], r[1] + r[3])
        switch rop {
        case patCopy: fillBrushRect(rect)
        case blackness: fillRectWith(rect, MetafileColor(0, 0, 0, 255))
        case whiteness: fillRectWith(rect, MetafileColor(255, 255, 255, 255))
        default: break
        }
    }

    /// Draws `text` (one `dx` advance per character, or none) with the current font, colours and alignment. The
    /// reference point is `at`, or the current position under TA_UPDATECP (which then moves past the string).
    /// `rect` (logical `[l, t, r, b]`) is filled with the background colour under ETO_OPAQUE and clips the text
    /// under ETO_CLIPPED. Text ignores the mix mode, as GDI's does.
    mutating func text(_ at: P, _ string: String, _ dx: [Float], _ options: UInt32, _ rect: R4?) {
        if options & etoOpaque != 0, let r = rect { fillRectWith(r, ts.bkColor) }
        let lf = ts.font ?? LogFont()
        let update = ts.align & taUpdateCP != 0
        let origin = update ? pos : at
        let (hAlign, vAlign) = align(ts.align)
        let o = map.device(origin)
        let ux0 = map.device(P(origin.x + 1, origin.y))
        let uy0 = map.device(P(origin.x, origin.y + 1))
        let (ux, uy) = (P(ux0.x - o.x, ux0.y - o.y), P(uy0.x - o.x, uy0.y - o.y))
        if update {
            // The current position moves along the baseline past the string (back past it when right-aligned).
            // Without a dx array the advance is estimated from the height.
            var adv: Double = dx.isEmpty
                ? Double(Swift.abs(lf.font.height).rustMax(1)) * 0.5 * Double(string.unicodeScalars.count)
                : rustSum(dx.map { Double($0) })
            adv = switch hAlign {
            case .left: adv
            case .right: -adv
            case .center: 0
            }
            let theta = (lf.escapement / 10).toRadians
            let ySign: Double = uy.y < 0 ? 1 : -1
            let sc = sinCos(theta)
            let p = P(origin.x + adv * sc.cos, origin.y + adv * sc.sin * ySign)
            if p.isFinite { pos = p }
        }
        let (sx, sy) = (hypot(ux.x, ux.y), hypot(uy.x, uy.y))
        let drawable = !string.isEmpty && [sx, sy, o.x, o.y].allSatisfy(\.isFinite) && sx > 0 && sy > 0
        guard drawable else { return }
        // The baseline runs along the device direction of the logical x axis (rotated by a world transform; a
        // mirroring mapping does not mirror glyphs), turned counter-clockwise by the escapement.
        let det = ux.x * uy.y - ux.y * uy.x
        let phi = det > 0 ? atan2(ux.y, ux.x) : atan2(ux.y, Swift.abs(ux.x))
        let a = phi - (lf.escapement / 10).toRadians
        let (s, c) = sinCos(a)
        var clipRect: SIMD4<Float>?
        if options & etoClipped != 0, let r = rect {
            let (p, q) = (map.device(P(r[0], r[1])), map.device(P(r[2], r[3])))
            clipRect = SIMD4<Float>(Float(p.x.rustMin(q.x)), Float(p.y.rustMin(q.y)), Float(p.x.rustMax(q.x)), Float(p.y.rustMax(q.y)))
        }
        push(.text(MetafileText(
            transform: [sx * c, sx * s, -sy * s, sy * c, o.x, o.y],
            text: string,
            dx: dx,
            font: lf.font,
            color: ts.color,
            background: ts.bkOpaque ? ts.bkColor : nil,
            hAlign: hAlign,
            vAlign: vAlign,
            clip: clipRect,
            region: nil
        ), region: nil))
    }

    /// A bitmap stretched into a logical rectangle `[x, y, w, h]`. A negative extent mirrors the bitmap, as the
    /// mapping does.
    mutating func bitmap(_ rect: R4, _ img: Rgba) {
        var img = img
        let (x, y, w, h) = (rect[0], rect[1], rect[2], rect[3])
        let a = map.device(P(x, y))
        let b = map.device(P(x + w, y + h))
        DIB.flip(&img, horizontal: a.x > b.x, vertical: a.y > b.y)
        let dev = R4(a.x.rustMin(b.x), a.y.rustMin(b.y), Swift.abs(b.x - a.x), Swift.abs(b.y - a.y))
        push(.bitmap(rect: dev, img: img, region: nil))
    }
}

/// An 8×8 hatch tile (HS_HORIZONTAL, HS_VERTICAL, HS_FDIAGONAL, HS_BDIAGONAL, HS_CROSS, HS_DIAGCROSS): one-pixel
/// lines in `fg` over `bg`, or over nothing when the background is transparent. nil for an unknown style.
func hatchTile(_ style: UInt32, _ fg: MetafileColor, _ bg: MetafileColor?) -> [UInt8]? {
    if style > 5 { return nil }
    var px: [UInt8] = []
    px.reserveCapacity(8 * 8 * 4)
    for y in 0 ..< 8 {
        for x in 0 ..< 8 {
            let (h, v, f, b) = (y == 7, x == 7, x == y, x + y == 7)
            let on = switch style {
            case 0: h
            case 1: v
            case 2: f
            case 3: b
            case 4: h || v
            default: f || b
            }
            let c = on ? fg : (bg ?? MetafileColor(0, 0, 0, 0))
            px += [c[0], c[1], c[2], c[3]]
        }
    }
    return px
}

/// Cubic segments from groups of three points (control, control, end). A trailing partial group is dropped.
private func cubics(_ pts: [P]) -> [Op] {
    stride(from: 0, to: pts.count - 2, by: 3).map { .c(pts[$0], pts[$0 + 1], pts[$0 + 2]) }
}

extension Int {
    /// Rust's `saturating_add`.
    func addingSaturating(_ o: Int) -> Int {
        let (v, overflow) = addingReportingOverflow(o)
        return overflow ? (o > 0 ? .max : .min) : v
    }
}

/// A set of object-table slots below `Metafile.maxObjects` (4096 = 64 × 64): one bit per slot and one summary bit
/// per word, so the lowest member is two bit scans away. Stands in for WordCraft's `BTreeSet<usize>`.
struct SlotSet {
    private var words = [UInt64](repeating: 0, count: 64)
    /// Bit `w` is set when `words[w]` is non-zero.
    private var summary: UInt64 = 0

    mutating func insert(_ i: Int) {
        guard i >= 0, i < 4096 else { return }
        words[i >> 6] |= 1 << UInt64(i & 63)
        summary |= 1 << UInt64(i >> 6)
    }

    mutating func remove(_ i: Int) {
        guard i >= 0, i < 4096 else { return }
        words[i >> 6] &= ~(1 << UInt64(i & 63))
        if words[i >> 6] == 0 { summary &= ~(1 << UInt64(i >> 6)) }
    }

    /// Removes and returns the lowest member.
    mutating func popFirst() -> Int? {
        guard summary != 0 else { return nil }
        let w = summary.trailingZeroBitCount
        let i = w << 6 | words[w].trailingZeroBitCount
        remove(i)
        return i
    }
}
