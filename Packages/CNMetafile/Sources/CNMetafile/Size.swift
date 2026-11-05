// CNMetafile — the size of a metafile picture without playing its records. Port of WordCraft
// crates/metafile/src/size.rs at 5a4c45e7 (MIT OR Apache-2.0, © ArtCraft Team and the WordCraft contributors)
// (c9ecb1a1).

extension Metafile {
    /// A placeable WMF header is 22 bytes, followed by the 9-word standard header.
    private static let placeableKey: UInt32 = 0x9AC6_CDD7
    private static let placeableLen = 22
    private static let defaultInch = 1440.0

    /// The size of a WMF or EMF picture in points (device or logical units when the file states no size), the same as
    /// `parse(bytes)` would put in the picture's `width` and `height`, or the error `parse` would throw.
    ///
    /// An EMF and a placeable WMF carry their frame in the header, so the size is read from there without decoding a
    /// bitmap or building a path. Any other file (a plain WMF, an EMF without a usable frame) takes the full parse.
    public static func size(_ bytes: [UInt8]) throws(MetafileError) -> (width: Float, height: Float) {
        let b = Bytes(bytes)
        if let size = headerSize(b) { return size }
        let pic = try parse(b, depth: 0)
        return (pic.width, pic.height)
    }

    /// The size when the header decides it and the file has a first record (otherwise `parse` fails with
    /// `.noRecords`, so the header alone is not enough). nil sends the caller to the full parse.
    static func headerSize(_ b: Bytes) -> (width: Float, height: Float)? {
        if EMF.isEMF(b) { return emfSize(b) }
        if WMF.isWMF(b) && b.u32(0) == placeableKey { return placeableWMFSize(b) }
        return nil
    }

    /// `rclFrame` mapped to points. The frame must pass the checks `build` applies to it.
    private static func emfSize(_ b: Bytes) -> (width: Float, height: Float)? {
        guard let hsize = b.u32(4).map(Int.init), b.slice(8, 16) != nil, let frame = EMF.frameFromHeader(b) else { return nil }
        guard frame.rect[0].isFinite, frame.rect[1].isFinite, frame.rect[2].isFinite, frame.rect[3].isFinite,
              frame.rect[2] > 0, frame.rect[3] > 0 else { return nil }
        // The records start after the header; the parse needs one that is not the end record.
        let pos = Swift.max(hsize, 88)
        guard let typ = b.u32(pos), let len = b.u32(pos + 4).map(Int.init) else { return nil }
        if len < 8 || len % 4 != 0 || b.slice(pos, len) == nil || typ == 14 { return nil }
        guard let (w, h) = frame.size else { return nil }
        return (f(w) ?? 0, f(h) ?? 0)
    }

    /// The placeable header's size in points, for a file whose records leave the target mapping alone (see
    /// `setsTheMapping`); the full parse decides the others.
    private static func placeableWMFSize(_ b: Bytes) -> (width: Float, height: Float)? {
        guard let l = b.i16(6), let t = b.i16(8), let r = b.i16(10), let bt = b.i16(12) else { return nil }
        let inch = b.u16(14).flatMap { $0 > 0 ? Double($0) : nil } ?? defaultInch
        let (w, h) = (Double(r) - Double(l), Double(bt) - Double(t))
        if w <= 0 || h <= 0 { return nil }
        guard let hsize = b.u16(placeableLen + 2).map(Int.init), hsize >= 9 else { return nil }
        let pos = placeableLen + hsize * 2
        guard let words = b.u32(pos).map(Int.init), let fn = b.u16(pos + 4) else { return nil }
        let len = words * 2
        if len < 6 || fn == 0 || b.slice(pos, len) == nil { return nil }
        if setsTheMapping(b, pos) { return nil }
        guard let fw = f(w * 72 / inch), let fh = f(h * 72 / inch) else { return nil }
        return (fw, fh)
    }

    /// Whether a record from `pos` on is SetMapMode (0x0103) or SetViewportExt (0x020E). Those can change the frame
    /// the full parse ends with (a zero-size viewport leaves none), so the header size is not enough. The records are
    /// only walked, not played, with the same stops as `WMF.parse`.
    private static func setsTheMapping(_ b: Bytes, _ start: Int) -> Bool {
        var pos = start
        // Each step moves at least 6 bytes and stops past the end, so the walk is bounded by the file's length.
        while let words = b.u32(pos), let fn = b.u16(pos + 4) {
            let len = Int(words) * 2
            if len < 6 || fn == 0 || b.slice(pos, len) == nil { return false }
            if fn == 0x0103 || fn == 0x020E { return true }
            pos += len
        }
        return false
    }
}
