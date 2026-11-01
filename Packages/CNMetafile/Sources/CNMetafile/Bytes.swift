// CNMetafile — bounds-checked little-endian access to hostile input. Port of deckcraft
// crates/metafile/src/bytes.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Every read returns nil past the end, so a truncated or lying size field stops the parse instead of
// trapping. A `Bytes` is a view into one shared buffer: slicing never copies.

struct Bytes {
    let buffer: [UInt8]
    let start: Int
    let count: Int

    init(_ buffer: [UInt8]) {
        self.buffer = buffer
        start = 0
        count = buffer.count
    }

    private init(buffer: [UInt8], start: Int, count: Int) {
        self.buffer = buffer
        self.start = start
        self.count = count
    }

    /// `len` bytes from `off`, or nil when they run past the end.
    func slice(_ off: Int, _ len: Int) -> Bytes? {
        guard off >= 0, len >= 0 else { return nil }
        let (end, overflow) = off.addingReportingOverflow(len)
        guard !overflow, end <= count else { return nil }
        return Bytes(buffer: buffer, start: start + off, count: len)
    }

    /// Everything from `off`, or nil past the end.
    func tail(_ off: Int) -> Bytes? {
        guard off >= 0, off <= count else { return nil }
        return Bytes(buffer: buffer, start: start + off, count: count - off)
    }

    /// The byte at `i`, or nil.
    func byte(_ i: Int) -> UInt8? {
        guard i >= 0, i < count else { return nil }
        return buffer[start + i]
    }

    /// The bytes as an array (a copy).
    var array: [UInt8] { Array(buffer[start ..< start + count]) }

    /// The bytes as a slice of the shared buffer.
    var view: ArraySlice<UInt8> { buffer[start ..< start + count] }

    private func le(_ off: Int, _ n: Int) -> UInt64? {
        guard let s = slice(off, n) else { return nil }
        var v: UInt64 = 0
        for k in 0 ..< n { v |= UInt64(s.buffer[s.start + k]) << (8 * UInt64(k)) }
        return v
    }

    func u16(_ off: Int) -> UInt16? { le(off, 2).map { UInt16(truncatingIfNeeded: $0) } }
    func i16(_ off: Int) -> Int16? { u16(off).map { Int16(bitPattern: $0) } }
    func u32(_ off: Int) -> UInt32? { le(off, 4).map { UInt32(truncatingIfNeeded: $0) } }
    func i32(_ off: Int) -> Int32? { u32(off).map { Int32(bitPattern: $0) } }
    func f32(_ off: Int) -> Float? { u32(off).map { Float(bitPattern: $0) } }

    /// `n` consecutive (x, y) pairs of 16- or 32-bit signed integers starting at `off`.
    func points(_ off: Int, _ n: Int, wide: Bool) -> [P]? {
        let sz = wide ? 8 : 4
        let (total, overflow) = n.multipliedReportingOverflow(by: sz)
        guard !overflow, let raw = slice(off, total) else { return nil }
        var out: [P] = []
        out.reserveCapacity(n)
        for k in 0 ..< n {
            let o = k * sz
            if wide {
                guard let x = raw.i32(o), let y = raw.i32(o + 4) else { return nil }
                out.append(P(Double(x), Double(y)))
            } else {
                guard let x = raw.i16(o), let y = raw.i16(o + 2) else { return nil }
                out.append(P(Double(x), Double(y)))
            }
        }
        return out
    }
}
