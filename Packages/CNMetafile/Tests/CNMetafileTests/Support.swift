// Hand-built WMF and EMF buffers for the tests: each test writes the records it needs and checks the parsed
// model. Port of the helpers in deckcraft crates/metafile/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).
@testable import CNMetafile
import Testing

func h16(_ v: Int) -> [UInt8] {
    let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
    return [UInt8(u & 0xFF), UInt8(u >> 8)]
}

func h32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
}

func e32(_ v: Int) -> [UInt8] {
    h32(UInt32(bitPattern: Int32(truncatingIfNeeded: v)))
}

func f32b(_ v: Float) -> [UInt8] {
    h32(v.bitPattern)
}

func u16b(_ v: UInt16) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8(v >> 8)]
}

func cat(_ parts: [[UInt8]]) -> [UInt8] {
    parts.flatMap { $0 }
}

/// One WMF record: size in words, function, parameters (padded to a word boundary).
func wrec(_ fn: UInt16, _ params: [UInt8]) -> [UInt8] {
    var p = params
    if p.count % 2 != 0 { p.append(0) }
    let words = UInt32((6 + p.count) / 2)
    return h32(words) + u16b(fn) + p
}

/// A WMF file: optional placeable header (bbox left, top, right, bottom in logical units, 1440 per inch), the
/// standard header, the records and an end-of-file record.
func wmf(_ records: [[UInt8]], _ placeable: [Int]?) -> [UInt8] {
    let body = records.flatMap { $0 }
    let eof = wrec(0, [])
    var f: [UInt8] = []
    if let bb = placeable {
        f += h32(0x9AC6_CDD7) + u16b(0)
        for v in bb { f += h16(v) }
        f += u16b(1440) + h32(0) + u16b(0)
    }
    let total = (f.count + 18 + body.count + eof.count) / 2
    f += u16b(1) + u16b(9) + u16b(0x300) + h32(UInt32(total)) + u16b(16) + h32(0) + u16b(0)
    return f + body + eof
}

/// One EMF record: type, size in bytes (payload padded to 4), payload.
func erec(_ typ: UInt32, _ payload: [UInt8]) -> [UInt8] {
    var p = payload
    while p.count % 4 != 0 { p.append(0) }
    return h32(typ) + h32(UInt32(8 + p.count)) + p
}

func put(_ v: inout [UInt8], _ at: Int, _ bytes: [UInt8]) {
    v.replaceSubrange(at ..< at + bytes.count, with: bytes)
}

/// An EMF file with an 88-byte header (bounds and frame in 0.01 mm), the records and an EOF record.
func emf(_ records: [[UInt8]], _ bounds: [Int], _ frame: [Int]) -> [UInt8] {
    let body = records.flatMap { $0 }
    let eof = erec(14, [UInt8](repeating: 0, count: 12))
    let total = 88 + body.count + eof.count
    var h = [UInt8](repeating: 0, count: 88)
    put(&h, 0, h32(1))
    put(&h, 4, h32(88))
    put(&h, 8, bounds.flatMap(e32))
    put(&h, 24, frame.flatMap(e32))
    put(&h, 40, h32(0x464D_4520))
    put(&h, 44, h32(0x0001_0000))
    put(&h, 48, h32(UInt32(total)))
    put(&h, 52, h32(UInt32(records.count + 1)))
    put(&h, 56, u16b(1))
    // 1000 x 500 device pixels for 250 x 125 mm: 0.04 device units per hundredth of a millimetre.
    put(&h, 72, e32(1000))
    put(&h, 76, e32(500))
    put(&h, 80, e32(250))
    put(&h, 84, e32(125))
    return h + body + eof
}

/// A BITMAPINFOHEADER (40 bytes).
func infoHeader(_ w: Int, _ h: Int, _ bpp: UInt16, _ sizeImage: UInt32) -> [UInt8] {
    cat([h32(40), e32(w), e32(h), h16(1), h16(Int(bpp)), h32(0), h32(sizeImage), e32(0), e32(0), h32(0), h32(0)])
}

/// A 2x2 24-bit bottom-up DIB. File rows are stored bottom first: the bottom image row is blue, green; the top
/// row is red, white. Rows are padded to 4 bytes (8 bytes per row).
func dib24BottomUp() -> [UInt8] {
    infoHeader(2, 2, 24, 16) + [255, 0, 0, 0, 255, 0, 0, 0] + [0, 0, 255, 255, 255, 255, 0, 0]
}

/// Top-down RGBA of `dib24BottomUp`: top-left red, top-right white, bottom-left blue, bottom-right green.
let dib24RGBA: [UInt8] = [255, 0, 0, 255, 255, 255, 255, 255, 0, 0, 255, 255, 0, 255, 0, 255]

/// A colour literal.
func C(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> MetafileColor {
    MetafileColor(r, g, b, a)
}

/// A stroke literal.
func S(_ c: MetafileColor, _ w: Float) -> MetafileStroke {
    MetafileStroke(color: c, width: w)
}

func parse(_ bytes: [UInt8]) throws(MetafileError) -> MetafilePicture {
    try Metafile.parse(bytes)
}

func isMetafile(_ bytes: [UInt8]) -> Bool {
    Metafile.isMetafile(bytes)
}

struct NotAPath: Error {}

func pathSegs(_ item: MetafileItem) throws -> ([MetafileSeg], MetafileColor?, MetafileStroke?, Bool) {
    guard case .path(let segs, let fill, let stroke, let evenOdd, _) = item else {
        Issue.record("expected a path: \(item)")
        throw NotAPath()
    }
    return (segs, fill, stroke, evenOdd)
}

struct Bitmap {
    var rect: SIMD4<Float>
    var width: UInt32
    var height: UInt32
    var rgba: [UInt8]
    var region: [SIMD4<Float>]?
}

func bitmap(_ item: MetafileItem) throws -> Bitmap {
    guard case .bitmap(let rect, let w, let h, let rgba, let region) = item else {
        Issue.record("expected a bitmap: \(item)")
        throw NotAPath()
    }
    return Bitmap(rect: rect, width: w, height: h, rgba: rgba, region: region)
}

func text(_ item: MetafileItem) throws -> MetafileText {
    guard case .text(let t) = item else {
        Issue.record("expected text: \(item)")
        throw NotAPath()
    }
    return t
}

func close(_ a: Float, _ b: Float) -> Bool {
    Swift.abs(a - b) < 1e-3
}

/// Segment equality within `close` tolerance.
func closeSeg(_ a: MetafileSeg, _ b: MetafileSeg) -> Bool {
    switch (a, b) {
    case let (.move(x, y), .move(u, v)), let (.line(x, y), .line(u, v)): close(x, u) && close(y, v)
    default: false
    }
}

/// The region of any item.
func region(_ item: MetafileItem) -> [SIMD4<Float>]? {
    switch item {
    case .path(_, _, _, _, let r), .bitmap(_, _, _, _, let r), .pattern(_, _, _, let r): r
    case .text(let t): t.region
    }
}

/// Fixed-seed LCG (Knuth's constants): the fuzz inputs are reproducible.
struct Lcg {
    var state: UInt64

    init(_ s: UInt64) { state = s }

    mutating func rnd() -> UInt32 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt32(truncatingIfNeeded: state >> 33)
    }
}

/// An EMF record of `len` bytes (header included) with u32 fields and byte blobs written at absolute record
/// offsets, so each test places a field where the spec puts it.
func erecAt(_ typ: UInt32, _ len: Int, _ fields: [(Int, UInt32)], _ blobs: [(Int, [UInt8])]) -> [UInt8] {
    var v = [UInt8](repeating: 0, count: len)
    put(&v, 0, h32(typ))
    put(&v, 4, h32(UInt32(len)))
    for (off, val) in fields { put(&v, off, h32(val)) }
    for (off, b) in blobs { put(&v, off, b) }
    return v
}

/// A BITBLT-style record (BITBLT, STRETCHBLT, ALPHABLEND layout) with its DIB at 112: the bmi and bits offsets
/// and lengths go at 84 and 92. `fields` and `blobs` add the other fields.
func dibRec(_ typ: UInt32, _ fields: [(Int, UInt32)], _ blobs: [(Int, [UInt8])], _ info: [UInt8], _ bits: [UInt8]) -> [UInt8] {
    let at = 112
    let bitsAt = at + info.count
    let f = fields + [(84, UInt32(at)), (88, UInt32(info.count)), (92, UInt32(bitsAt)), (96, UInt32(bits.count))]
    return erecAt(typ, bitsAt + bits.count, f, blobs + [(at, info), (bitsAt, bits)])
}

/// BITBLT (76) with destination `dst` = [x, y, w, h] and a 40-byte header DIB.
func bitbltRec(_ rop: UInt32, _ dst: [UInt32], _ info: [UInt8], _ bits: [UInt8]) -> [UInt8] {
    dibRec(76, [(24, dst[0]), (28, dst[1]), (32, dst[2]), (36, dst[3]), (40, rop)], [], info, bits)
}

/// A WMF rectangle from (0, 0) to (1, 1), so a picture's frame starts at the origin.
func originRect() -> [UInt8] {
    wrec(0x041B, cat([h16(1), h16(1), h16(0), h16(0)]))
}

/// An XFORM record payload.
func xformBytes(_ v: [Float]) -> [UInt8] {
    v.flatMap(f32b)
}

struct MissingItem: Error {}

/// Item `i`, or a recorded failure (Rust's indexing panics; Swift's would end the test run).
func item(_ p: MetafilePicture, _ i: Int) throws -> MetafileItem {
    guard i >= 0, i < p.items.count else {
        Issue.record("no item \(i) in \(p.items.count)")
        throw MissingItem()
    }
    return p.items[i]
}

/// `segs[i]`, or a recorded failure.
func seg(_ segs: [MetafileSeg], _ i: Int) throws -> MetafileSeg {
    guard i >= 0, i < segs.count else {
        Issue.record("no segment \(i) in \(segs)")
        throw MissingItem()
    }
    return segs[i]
}
