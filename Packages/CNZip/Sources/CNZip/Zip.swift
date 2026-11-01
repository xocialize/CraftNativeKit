// CNZip — copied from PhotoCraftNative (xocialize/PhotoCraftNative, Packages/PCIO/Sources/PCIOCore/Zip.swift at
// 7fa4dcc), which ports photocraft (MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors).
// Used by DeckCraftNative (DCFormat, DCPPTX) and Marquee Documents. Errors are `ZipError` here.
//
// Minimal ZIP container: STORE entries are written (`.pcraft` payloads are already compressed;
// OpenRaster's `mimetype` must be stored); STORE or DEFLATE entries are read, so a bundle that was
// unzipped and re-zipped by another tool still loads, and OpenRaster/Krita archives open.
//
// ZIP64 (APPNOTE 6.3.10 §4.3.14–4.3.16, §4.5.3) is written only when an archive outgrows the
// classic fields: 65,535 entries, or 4 GiB for an entry, an offset or the central directory. An
// archive that fits is byte for byte the classic layout photocraft writes, so readers without
// ZIP64 still open it. ZIP64 from any writer is read. No encryption, no multi-disk archives.
//
// Two writers lay out the same bytes: `ZipWriter` builds the archive in memory; `ZipStreamWriter`
// streams it entry by entry into a `ZipSink` (a file), keeping only the central directory, so a
// multi-gigabyte `.pcraft` is never held whole. Every entry's CRC and sizes are known before its
// local header is written, so no data descriptors are needed and the layout is the classic one.
// Two readers parse the same way: `ZipReader` over bytes in memory, `ZipFileReader` over an open
// file, reading the end records, the central directory and each entry as it is asked for.
// Port of photocraft-format (crates/format/src/zip.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors; ZIP64 and streaming are this port's (`.pcraft` format 2). DEFLATE
// through Apple's Compression framework (`Deflate`).

import Foundation

private let localSignature: UInt32 = 0x0403_4B50
private let centralSignature: UInt32 = 0x0201_4B50
private let endSignature: UInt32 = 0x0605_4B50
private let zip64EndSignature: UInt32 = 0x0606_4B50
private let zip64LocatorSignature: UInt32 = 0x0706_4B50
/// Header id of the ZIP64 extended information extra field.
private let zip64ExtraId = 1
/// Classic field values that mean "see the ZIP64 record". A value equal to one is ambiguous, so
/// it, too, goes to ZIP64.
private let max16 = 0xFFFF
private let max32 = 0xFFFF_FFFF
/// "Version needed to extract": 2.0 classic, 4.5 for ZIP64 records.
private let versionClassic: UInt16 = 20
private let versionZip64: UInt16 = 45

// MARK: - Layout

/// The records both writers produce: each entry's local header and central directory entry, and
/// the end records. Holds the central directory until the archive is finished.
struct ZipLayout: Sendable {
    /// Where an entry's records are, so a STORE entry can be rewritten (`replaceStored`).
    struct Placed: Sendable {
        var local: Int, data: Int, central: Int, size: Int, method: UInt16
    }

    var central: [UInt8] = []
    /// Entries so far. Where each one is isn't kept beside the central directory, which says it (AB-T-0328).
    private(set) var count = 0
    var entryUsedZip64 = false
    let forceZip64: Bool

    init(forceZip64: Bool) { self.forceZip64 = forceZip64 }

    /// Where entry `index` is, read back from its central directory entry as `entry` wrote it: a size or offset is
    /// in the ZIP64 field (sizes first) exactly when its classic field holds `max32`, and the local header has a
    /// ZIP64 field exactly when the sizes are in one.
    func placed(_ index: Int) -> Placed? {
        guard index >= 0, index < count else { return nil }
        func u16(_ i: Int) -> Int { Int(central[i]) | Int(central[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        func u64(_ i: Int) -> Int { u32(i) | u32(i + 4) << 32 }
        var at = 0
        for _ in 0 ..< index { at += 46 + u16(at + 28) + u16(at + 30) + u16(at + 32) }
        let nameLength = u16(at + 28)
        var size = u32(at + 20), offset = u32(at + 42)
        var field = at + 46 + nameLength + 4
        let sizes64 = size == max32
        if sizes64 {
            size = u64(field + 8)
            field += 16
        }
        if offset == max32 { offset = u64(field) }
        let data = offset + 30 + nameLength + (sizes64 ? 20 : 0)
        return Placed(local: offset, data: data, central: at, size: size, method: UInt16(u16(at + 10)))
    }

    /// Whether the archive, finished after `written` bytes of local headers and data, has ZIP64
    /// records.
    func usesZip64(written: Int) -> Bool {
        forceZip64 || entryUsedZip64 || count >= max16 || written >= max32 || central.count >= max32
    }

    /// Records an entry whose local header starts at `offset`, and returns that header.
    mutating func entry(_ name: String, method: UInt16, crc: UInt32, compressedSize csize: Int, uncompressedSize usize: Int,
                        offset: Int) throws -> [UInt8] {
        let nameBytes = Array(name.utf8)
        guard nameBytes.count <= max16 else { throw ZipError.unsupported("zip entry name too long") }
        // The local header carries both sizes in its ZIP64 field or neither (§4.5.3); the central
        // one carries the sizes and the offset that overflow, in that order.
        let sizes64 = forceZip64 || usize >= max32 || csize >= max32
        let offset64 = forceZip64 || offset >= max32
        let needed = sizes64 || offset64 ? versionZip64 : versionClassic
        if sizes64 || offset64 { entryUsedZip64 = true }
        // Local file header.
        var out: [UInt8] = []
        out.reserveCapacity(30 + nameBytes.count + 20)
        le32(&out, localSignature)
        le16(&out, sizes64 ? versionZip64 : versionClassic) // version needed
        le16(&out, 0x0800) // flags: UTF-8 names
        le16(&out, method)
        le16(&out, 0) // time
        le16(&out, 0x21) // date: 1980-01-01
        le32(&out, crc)
        le32(&out, sizes64 ? UInt32(max32) : UInt32(csize))
        le32(&out, sizes64 ? UInt32(max32) : UInt32(usize))
        le16(&out, UInt16(nameBytes.count))
        le16(&out, sizes64 ? 20 : 0) // extra length
        out += nameBytes
        if sizes64 {
            le16(&out, UInt16(zip64ExtraId))
            le16(&out, 16)
            le64(&out, UInt64(usize))
            le64(&out, UInt64(csize))
        }
        // Central directory entry.
        count += 1
        let extraLength = (sizes64 ? 16 : 0) + (offset64 ? 8 : 0)
        le32(&central, centralSignature)
        le16(&central, needed) // made by (MS-DOS attributes, this spec version)
        le16(&central, needed)
        le16(&central, 0x0800)
        le16(&central, method)
        le16(&central, 0)
        le16(&central, 0x21)
        le32(&central, crc)
        le32(&central, sizes64 ? UInt32(max32) : UInt32(csize))
        le32(&central, sizes64 ? UInt32(max32) : UInt32(usize))
        le16(&central, UInt16(nameBytes.count))
        le16(&central, extraLength == 0 ? 0 : UInt16(4 + extraLength))
        central += [UInt8](repeating: 0, count: 6) // comment len, disk, internal attrs
        le32(&central, 0) // external attrs
        le32(&central, offset64 ? UInt32(max32) : UInt32(offset))
        central += nameBytes
        if extraLength > 0 {
            le16(&central, UInt16(zip64ExtraId))
            le16(&central, UInt16(extraLength))
            if sizes64 {
                le64(&central, UInt64(usize))
                le64(&central, UInt64(csize))
            }
            if offset64 { le64(&central, UInt64(offset)) }
        }
        return out
    }

    /// Checks that STORE entry `index` can take `size` new bytes, sets its CRC to `crc` in the
    /// central directory, and returns where its local header's CRC and its data are.
    mutating func replace(_ index: Int, size: Int, crc: UInt32) throws -> (crcOffset: Int, dataOffset: Int) {
        guard placed(index)?.size == size else {
            throw ZipError.unsupported("zip entry \(index): only a STORE entry's bytes can be replaced, with as many bytes")
        }
        return try patch(index, within: 0 ..< size, crc: crc)
    }

    /// Checks that `range` lies within STORE entry `index`'s bytes, sets the entry's CRC to `crc` in the central
    /// directory, and returns where its local header's CRC and its data are.
    mutating func patch(_ index: Int, within range: Range<Int>, crc: UInt32) throws -> (crcOffset: Int, dataOffset: Int) {
        guard let p = placed(index), p.method == 0, range.lowerBound >= 0, range.upperBound <= p.size else {
            throw ZipError.unsupported("zip entry \(index): only a STORE entry's bytes can be replaced, within its length")
        }
        var c: [UInt8] = []
        le32(&c, crc)
        central.replaceSubrange(p.central + 16 ..< p.central + 20, with: c)
        return (p.local + 14, p.data)
    }

    /// The end records for a central directory of `central.count` bytes at `cdOffset`, after
    /// `written` bytes of local headers and data (= `cdOffset`).
    func end(cdOffset: Int) -> [UInt8] {
        let zip64 = usesZip64(written: cdOffset)
        let cdSize = central.count, count = count
        var o: [UInt8] = []
        o.reserveCapacity(56 + 20 + 22)
        if zip64 {
            // ZIP64 end of central directory record and its locator (§4.3.14, §4.3.15).
            let record = cdOffset + cdSize
            le32(&o, zip64EndSignature)
            le64(&o, 44) // size of the rest of the record
            le16(&o, versionZip64) // made by
            le16(&o, versionZip64) // needed
            le32(&o, 0) // this disk
            le32(&o, 0) // disk with the central directory
            le64(&o, UInt64(count)) // entries on this disk
            le64(&o, UInt64(count))
            le64(&o, UInt64(cdSize))
            le64(&o, UInt64(cdOffset))
            le32(&o, zip64LocatorSignature)
            le32(&o, 0) // disk with the ZIP64 end record
            le64(&o, UInt64(record))
            le32(&o, 1) // total disks
        }
        // The classic end record; a field that doesn't fit (or every field, when forced) says
        // "see ZIP64" (§4.4.1.4).
        let entries16 = forceZip64 || count >= max16 ? UInt16(max16) : UInt16(count)
        le32(&o, endSignature)
        o += [0, 0, 0, 0] // disk numbers
        le16(&o, entries16)
        le16(&o, entries16)
        le32(&o, forceZip64 || cdSize >= max32 ? UInt32(max32) : UInt32(cdSize))
        le32(&o, forceZip64 || cdOffset >= max32 ? UInt32(max32) : UInt32(cdOffset))
        le16(&o, 0)
        return o
    }
}

private func le16(_ o: inout [UInt8], _ v: UInt16) { o += [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func le32(_ o: inout [UInt8], _ v: UInt32) { o += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
private func le64(_ o: inout [UInt8], _ v: UInt64) { le32(&o, UInt32(v & 0xFFFF_FFFF)); le32(&o, UInt32(v >> 32)) }

// MARK: - Writing in memory

/// Writer for STORE entries (and optionally DEFLATE ones), as classic ZIP or, when the archive
/// needs it, ZIP64.
public struct ZipWriter: Sendable {
    private var out: [UInt8] = []
    private var layout: ZipLayout

    /// `forceZip64` writes every ZIP64 field (each size and offset, and the ZIP64 end records) even
    /// where the classic one fits: for tests and interop checks of small archives.
    public init(forceZip64: Bool = false) { layout = ZipLayout(forceZip64: forceZip64) }

    /// Bytes written so far (local headers and data).
    public var size: Int { out.count }

    /// Whether the archive, if finished now, has ZIP64 records.
    public var usesZip64: Bool { layout.usesZip64(written: out.count) }

    /// Reserves room for `bytes` of local headers and data (an archive's expected size), so a
    /// multi-gigabyte archive isn't regrown and copied as it is written.
    public mutating func reserveCapacity(_ bytes: Int) { out.reserveCapacity(bytes) }

    /// Whether STORE entries with these name lengths (UTF-8 bytes) and sizes, in this order, make a
    /// classic archive: `usesZip64` is false after adding exactly them (without `forceZip64`).
    public static func fitsClassic(_ entries: some Sequence<(nameLength: Int, size: Int)>) -> Bool {
        var count = 0, local = 0, cd = 0
        for e in entries {
            if e.size >= max32 || local >= max32 { return false }
            local += 30 + e.nameLength + e.size
            cd += 46 + e.nameLength
            count += 1
        }
        return count < max16 && local < max32 && cd < max32
    }

    /// Adds a STORE entry.
    public mutating func add(_ name: String, _ data: [UInt8]) throws {
        try add(name, data, compress: false)
    }

    /// Adds an entry, DEFLATE-compressed when `compress` and it saves space.
    public mutating func add(_ name: String, _ data: [UInt8], compress: Bool) throws {
        let crc = CRC32.checksum(data)
        if compress, let d = try? Deflate.deflate(data), d.count < data.count {
            try append(name, d, method: 8, crc: crc, uncompressedSize: data.count)
        } else {
            try append(name, data, method: 0, crc: crc, uncompressedSize: data.count)
        }
    }

    /// Adds a STORE entry whose CRC-32 the caller already has (computed in parallel, or kept from
    /// an earlier save). `crc` must be `CRC32.checksum(data)`.
    public mutating func addStored(_ name: String, _ data: [UInt8], crc: UInt32) throws {
        try append(name, data, method: 0, crc: crc, uncompressedSize: data.count)
    }

    /// Replaces the bytes of STORE entry `index` (in the order added) with `data` of the same
    /// length, whose CRC-32 is `crc`.
    public mutating func replaceStored(_ index: Int, _ data: [UInt8], crc: UInt32) throws {
        let (crcOffset, dataOffset) = try layout.replace(index, size: data.count, crc: crc)
        var c: [UInt8] = []
        le32(&c, crc)
        out.replaceSubrange(crcOffset ..< crcOffset + 4, with: c)
        out.replaceSubrange(dataOffset ..< dataOffset + data.count, with: data)
    }

    private mutating func append(_ name: String, _ payload: [UInt8], method: UInt16, crc: UInt32, uncompressedSize usize: Int) throws {
        out += try layout.entry(name, method: method, crc: crc, compressedSize: payload.count, uncompressedSize: usize, offset: out.count)
        out += payload
    }

    /// The finished archive.
    public consuming func finish() throws -> [UInt8] {
        let end = layout.end(cdOffset: out.count)
        // Appended in place: copying a multi-gigabyte archive here would double its memory.
        var o: [UInt8] = []
        swap(&o, &out)
        o.reserveCapacity(o.count + layout.central.count + end.count)
        o += layout.central
        o += end
        return o
    }
}

// MARK: - Streaming

/// Where `ZipStreamWriter` puts an archive: bytes appended in order, and earlier ones rewritten in
/// place (`replaceStored`).
public protocol ZipSink {
    /// Appends `bytes`.
    mutating func write(_ bytes: UnsafeRawBufferPointer) throws
    /// Replaces `bytes.count` bytes written earlier, from `offset`.
    mutating func overwrite(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws
    /// Writes out anything buffered (the archive is finished).
    mutating func flush() throws
}

extension ZipSink {
    public mutating func flush() throws {}
}

/// An archive in memory, as a `ZipSink`.
public struct ZipMemorySink: ZipSink, Sendable {
    public var bytes: [UInt8] = []

    public init() {}

    public mutating func write(_ b: UnsafeRawBufferPointer) throws { bytes.append(contentsOf: b.assumingMemoryBound(to: UInt8.self)) }

    public mutating func overwrite(_ b: UnsafeRawBufferPointer, at offset: Int) throws {
        guard offset >= 0, offset + b.count <= bytes.count else { throw ZipError.io("overwrite past the end of the archive") }
        bytes.replaceSubrange(offset ..< offset + b.count, with: b.assumingMemoryBound(to: UInt8.self))
    }
}

/// `ZipWriter`'s archive, written entry by entry into `sink` as it is added: the same bytes, but
/// only the central directory (about 50 bytes per entry plus its name) is kept until `finish`.
public struct ZipStreamWriter<Sink: ZipSink> {
    public private(set) var sink: Sink
    private var layout: ZipLayout
    private var written = 0

    /// `forceZip64` as for `ZipWriter`.
    public init(_ sink: Sink, forceZip64: Bool = false) {
        self.sink = sink
        layout = ZipLayout(forceZip64: forceZip64)
    }

    /// Bytes written so far (local headers and data).
    public var size: Int { written }

    /// Whether the archive, if finished now, has ZIP64 records.
    public var usesZip64: Bool { layout.usesZip64(written: written) }

    /// Adds a STORE entry.
    public mutating func add(_ name: String, _ data: [UInt8]) throws {
        try addStored(name, data, crc: CRC32.checksum(data))
    }

    /// Adds a STORE entry whose CRC-32 the caller already has. `crc` must be `CRC32.checksum(data)`.
    public mutating func addStored(_ name: String, _ data: [UInt8], crc: UInt32) throws {
        let header = try layout.entry(name, method: 0, crc: crc, compressedSize: data.count, uncompressedSize: data.count, offset: written)
        try put(header)
        try put(data)
    }

    /// Replaces the bytes of STORE entry `index` (in the order added) with `data` of the same
    /// length, whose CRC-32 is `crc`: a header whose content is only settled once later entries
    /// are written.
    public mutating func replaceStored(_ index: Int, _ data: [UInt8], crc: UInt32) throws {
        let (crcOffset, dataOffset) = try layout.replace(index, size: data.count, crc: crc)
        var c: [UInt8] = []
        le32(&c, crc)
        try c.withUnsafeBytes { try sink.overwrite($0, at: crcOffset) }
        try data.withUnsafeBytes { try sink.overwrite($0, at: dataOffset) }
    }

    /// Rewrites `bytes` at `offset` in STORE entry `index`, whose CRC-32 as rewritten is `crc`: an entry whose content
    /// is only settled once later entries are written, without keeping all of it (AB-T-0328).
    package mutating func patchStored(_ index: Int, at offset: Int, _ bytes: [UInt8], crc: UInt32) throws {
        let (crcOffset, dataOffset) = try layout.patch(index, within: offset ..< offset + bytes.count, crc: crc)
        var c: [UInt8] = []
        le32(&c, crc)
        try c.withUnsafeBytes { try sink.overwrite($0, at: crcOffset) }
        try bytes.withUnsafeBytes { try sink.overwrite($0, at: dataOffset + offset) }
    }

    private mutating func put(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try sink.write($0) }
        written += bytes.count
    }

    /// Writes the central directory and end records, flushes, and returns the sink.
    public consuming func finish() throws -> Sink {
        let end = layout.end(cdOffset: written)
        let central = layout.central
        layout.central = []
        try put(central)
        try put(end)
        try sink.flush()
        return sink
    }
}

// MARK: - Reading

/// One entry of a `ZipReader`.
public struct ZipEntry: Hashable, Sendable {
    public var name: String
    public var method: UInt16
    public var crc: UInt32
    public var compressedSize: Int
    public var uncompressedSize: Int
    public var dataOffset: Int
}

/// An archive's bytes, read by range: in memory or in a file.
protocol ZipBytes {
    var count: Int { get }
    /// The bytes in `range`; one outside `0 ..< count` is a truncated archive.
    func bytes(_ range: Range<Int>) throws -> [UInt8]
}

struct ZipArrayBytes: ZipBytes {
    let array: [UInt8]
    var count: Int { array.count }

    func bytes(_ range: Range<Int>) throws -> [UInt8] {
        guard range.lowerBound >= 0, range.upperBound <= array.count else { throw ZipError.corrupt("truncated zip") }
        return Array(array[range])
    }
}

/// The parsing both readers share.
enum ZipDirectory {
    /// The entries of the archive in `src` (central-directory order) and whether it is ZIP64.
    static func read(_ src: some ZipBytes) throws -> (entries: [ZipEntry], isZip64: Bool) {
        let size = src.count
        guard size >= 22 else { throw ZipError.corrupt("not a zip archive (too short)") }
        // End of central directory: scan back over a possible comment. The tail read also holds
        // the ZIP64 locator, 20 bytes before the end record.
        let minimum = max(0, size - 22 - 65535)
        let tailStart = max(0, minimum - 20)
        let tail = try src.bytes(tailStart ..< size)
        var eocd: Int?
        var i = size - 22
        while i >= minimum {
            if (try? ZipReader.u32(tail, i - tailStart)) == Int(endSignature) { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw ZipError.corrupt("zip end-of-central-directory not found") }
        let e = eocd - tailStart
        var count = try ZipReader.u16(tail, e + 10)
        var cdSize = try ZipReader.u32(tail, e + 12)
        var cdOffset = try ZipReader.u32(tail, e + 16)
        var cdLimit = eocd
        var zip64 = false
        // ZIP64: the record the locator points at replaces the classic counts. A damaged one is
        // an error only when the classic end record defers to it; otherwise the four bytes before
        // the end record merely happened to match the locator's signature.
        let defers = count == max16 || cdSize == max32 || cdOffset == max32
        do {
            if let z = try zip64End(src, tail: tail, tailStart: tailStart, eocd: eocd) {
                (count, cdSize, cdOffset, cdLimit) = (z.count, z.cdSize, z.cdOffset, z.record)
                zip64 = true
            } else if defers {
                throw ZipError.corrupt("zip64 end of central directory not found")
            }
        } catch {
            if defers { throw error }
        }
        let (cdEnd, overflow) = cdOffset.addingReportingOverflow(cdSize)
        guard !overflow, cdEnd <= cdLimit else { throw ZipError.corrupt("zip central directory out of range") }
        let cd = try src.bytes(cdOffset ..< cdEnd)
        var entries: [ZipEntry] = []
        entries.reserveCapacity(min(count, cdSize / 46))
        // Offsets below are into `cd`.
        var p = 0
        for _ in 0 ..< count {
            let headerEnd = p + 46
            guard headerEnd <= cd.count else { throw ZipError.corrupt("truncated zip central directory entry") }
            guard try ZipReader.u32(cd, p) == Int(centralSignature) else { throw ZipError.corrupt("bad zip central directory entry") }
            let flags = try ZipReader.u16(cd, p + 8)
            let method = try ZipReader.u16(cd, p + 10)
            let crc = try ZipReader.u32(cd, p + 16)
            var compressed = try ZipReader.u32(cd, p + 20)
            var uncompressed = try ZipReader.u32(cd, p + 24)
            let nlen = try ZipReader.u16(cd, p + 28)
            let elen = try ZipReader.u16(cd, p + 30)
            let clen = try ZipReader.u16(cd, p + 32)
            var local = try ZipReader.u32(cd, p + 42)
            let nameEnd = headerEnd + nlen
            guard nameEnd <= cd.count else { throw ZipError.corrupt("zip entry name out of range") }
            let name = String(decoding: cd[headerEnd ..< nameEnd], as: UTF8.self)
            if flags & 1 != 0 { throw ZipError.unsupported("encrypted zip entries") }
            let entryEnd = nameEnd + elen + clen
            guard entryEnd <= cd.count else { throw ZipError.corrupt("zip central directory entry out of range") }
            // ZIP64 extended information: the fields set to 0xFFFFFFFF, in this order (§4.5.3).
            // Without one, a field means its classic value (as Info-ZIP and Python read it); the
            // range checks below bound it either way.
            if uncompressed == max32 || compressed == max32 || local == max32,
               let z = try ZipReader.zip64Extra(cd, nameEnd ..< nameEnd + elen) {
                var q = z.lowerBound
                func next() throws -> Int {
                    guard q + 8 <= z.upperBound else { throw ZipError.corrupt("zip entry `\(name)`: truncated zip64 field") }
                    defer { q += 8 }
                    return try ZipReader.u64(cd, q)
                }
                if uncompressed == max32 { uncompressed = try next() }
                if compressed == max32 { compressed = try next() }
                if local == max32 { local = try next() }
            }
            // The local header gives the real data offset.
            guard local <= size else { throw ZipError.corrupt("truncated zip") }
            let header = try src.bytes(local ..< min(local + 30, size))
            guard try ZipReader.u32(header, 0) == Int(localSignature) else { throw ZipError.corrupt("bad zip local header") }
            let lnlen = try ZipReader.u16(header, 26)
            let lelen = try ZipReader.u16(header, 28)
            let dataOffset = local + 30 + lnlen + lelen
            let (end, o2) = dataOffset.addingReportingOverflow(compressed)
            guard !o2, end <= size else { throw ZipError.corrupt("zip entry `\(name)` out of range") }
            entries.append(ZipEntry(name: name, method: UInt16(method), crc: UInt32(crc), compressedSize: compressed,
                                    uncompressedSize: uncompressed, dataOffset: dataOffset))
            p = entryEnd
        }
        return (entries, zip64)
    }

    /// The ZIP64 end record's (entries, central directory size, central directory offset, record
    /// offset), when a valid locator precedes the end record at `eocd`.
    static func zip64End(_ src: some ZipBytes, tail: [UInt8], tailStart: Int, eocd: Int) throws
        -> (count: Int, cdSize: Int, cdOffset: Int, record: Int)? {
        let locator = eocd - 20
        guard locator >= tailStart, (try? ZipReader.u32(tail, locator - tailStart)) == Int(zip64LocatorSignature) else { return nil }
        let record = try ZipReader.u64(tail, locator - tailStart + 8)
        guard record <= locator - 56 else { throw ZipError.corrupt("zip64 end of central directory out of range") }
        let r = try src.bytes(record ..< record + 56)
        guard try ZipReader.u32(r, 0) == Int(zip64EndSignature) else {
            throw ZipError.corrupt("zip64 end of central directory out of range")
        }
        // Total entries, central directory size and offset.
        return (try ZipReader.u64(r, 32), try ZipReader.u64(r, 40), try ZipReader.u64(r, 48), record)
    }

    /// Entry `e`'s payload (decompressed), at most `max` bytes, CRC-checked; `raw` reads its stored
    /// bytes, whose range has been checked against `size`.
    static func payload(_ e: ZipEntry, max: Int, size: Int, _ raw: (Range<Int>) throws -> [UInt8]) throws -> [UInt8] {
        if e.uncompressedSize > max {
            throw ZipError.limitExceeded("zip entry `\(e.name)` is \(e.uncompressedSize) bytes (max \(max))")
        }
        // An entry from another archive must not index out of range.
        let (end, overflow) = e.dataOffset.addingReportingOverflow(e.compressedSize)
        guard !overflow, e.dataOffset >= 0, end <= size else { throw ZipError.corrupt("zip entry `\(e.name)` out of range") }
        let data: [UInt8]
        switch e.method {
        case 0:
            // A stored entry is its own size: don't read a forged length.
            guard e.compressedSize == e.uncompressedSize else { throw ZipError.corrupt("zip entry `\(e.name)` has wrong size") }
            data = try raw(e.dataOffset ..< end)
        case 8:
            let compressed = try raw(e.dataOffset ..< end)
            do {
                data = try Deflate.inflate(compressed, limit: max == .max ? .max : max + 1)
            } catch ZipError.limitExceeded(_) {
                throw ZipError.corrupt("zip entry `\(e.name)` has wrong size")
            } catch {
                throw ZipError.corrupt("zip entry `\(e.name)`: \(error)")
            }
        default:
            throw ZipError.unsupported("zip compression method \(e.method) for `\(e.name)`")
        }
        if data.count != e.uncompressedSize || data.count > max { throw ZipError.corrupt("zip entry `\(e.name)` has wrong size") }
        if CRC32.checksum(data) != e.crc { throw ZipError.corrupt("zip entry `\(e.name)` failed its CRC check") }
        return data
    }

    /// Name → index of the first entry with that name (duplicates: the first wins).
    static func index(_ entries: [ZipEntry]) -> [String: Int] {
        var byName: [String: Int] = [:]
        byName.reserveCapacity(entries.count)
        for (k, e) in entries.enumerated() where byName[e.name] == nil { byName[e.name] = k }
        return byName
    }
}

/// Read-only view of an archive in memory.
public struct ZipReader: Sendable {
    public let bytes: [UInt8]
    /// All entries, in central-directory order.
    public let entries: [ZipEntry]
    /// Whether the archive has a ZIP64 end of central directory record.
    public let isZip64: Bool
    /// Name → index of the first entry with that name (duplicates: the first wins).
    private let byName: [String: Int]

    static func u16(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o <= b.count - 2 else { throw ZipError.corrupt("truncated zip") }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o <= b.count - 4 else { throw ZipError.corrupt("truncated zip") }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    /// A ZIP64 count, size or offset; one beyond `Int.max` is corrupt.
    static func u64(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o <= b.count - 8 else { throw ZipError.corrupt("truncated zip") }
        var v: UInt64 = 0
        for k in 0 ..< 8 { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
        guard let i = Int(exactly: v) else { throw ZipError.corrupt("zip64 value \(v) out of range") }
        return i
    }

    /// The bounds of the ZIP64 extended information field among the extra fields in `range`.
    static func zip64Extra(_ bytes: [UInt8], _ range: Range<Int>) throws -> Range<Int>? {
        var q = range.lowerBound
        while q + 4 <= range.upperBound {
            let id = try u16(bytes, q), size = try u16(bytes, q + 2)
            let end = q + 4 + size
            guard end <= range.upperBound else { throw ZipError.corrupt("zip extra field out of range") }
            if id == zip64ExtraId { return q + 4 ..< end }
            q = end
        }
        return nil
    }

    public init(_ bytes: [UInt8]) throws {
        (entries, isZip64) = try ZipDirectory.read(ZipArrayBytes(array: bytes))
        self.bytes = bytes
        byName = ZipDirectory.index(entries)
    }

    public func find(_ name: String) -> ZipEntry? { byName[name].map { entries[$0] } }

    /// Entry payload (decompressed), at most `max` bytes, CRC-checked.
    public func read(_ e: ZipEntry, max: Int) throws -> [UInt8] {
        try ZipDirectory.payload(e, max: max, size: bytes.count) { Array(bytes[$0]) }
    }

    public func read(named name: String, max: Int) throws -> [UInt8] {
        guard let e = find(name) else { throw ZipError.corrupt("missing `\(name)`") }
        return try read(e, max: max)
    }

    /// The payload of a ZIP's first entry when it is a stored file named `mimetype` (how
    /// OpenRaster and Krita mark their archives, readable without unzipping) (photocraft
    /// `ora::zip_mimetype`).
    public static func mimetype(_ bytes: [UInt8]) -> [UInt8]? {
        guard (try? u32(bytes, 0)) == Int(localSignature), (try? u16(bytes, 8)) == 0,
              let size = try? u32(bytes, 18), let nameLen = try? u16(bytes, 26), let extraLen = try? u16(bytes, 28),
              bytes.count >= 30 + nameLen, Array(bytes[30 ..< 30 + nameLen]) == Array("mimetype".utf8), size <= 256 else { return nil }
        let start = 30 + nameLen + extraLen
        guard start + size <= bytes.count else { return nil }
        return Array(bytes[start ..< start + size])
    }
}

/// A read-only file, read by range with `pread` (safe from several threads at once). Closes its
/// descriptor when it goes.
final class ZipFile: ZipBytes, Sendable {
    let fd: Int32
    let count: Int

    /// Takes ownership of `fd`.
    init(fd: Int32) throws {
        self.fd = fd
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            count = 0
            throw ZipError.io("zip file: \(String(cString: strerror(errno)))")
        }
        count = Int(max(0, st.st_size))
    }

    deinit { close(fd) }

    func bytes(_ range: Range<Int>) throws -> [UInt8] {
        guard range.lowerBound >= 0, range.upperBound <= count else { throw ZipError.corrupt("truncated zip") }
        let n = range.count
        return try [UInt8](unsafeUninitializedCapacity: n) { buf, initialized in
            var done = 0
            while done < n {
                let got = pread(fd, buf.baseAddress! + done, n - done, off_t(range.lowerBound + done))
                if got < 0 {
                    if errno == EINTR { continue }
                    throw ZipError.io("zip file: \(String(cString: strerror(errno)))")
                }
                // The file shrank since it was opened.
                if got == 0 { throw ZipError.corrupt("truncated zip") }
                done += got
            }
            initialized = n
        }
    }
}

/// Read-only view of an archive in a file: the end records and central directory are read when it
/// opens, each entry's bytes when they are asked for, so memory stays proportional to the entry
/// count, not the file. Entries may be read from several threads at once.
public struct ZipFileReader: Sendable {
    private let file: ZipFile
    /// All entries, in central-directory order.
    public let entries: [ZipEntry]
    /// Whether the archive has a ZIP64 end of central directory record.
    public let isZip64: Bool
    private let byName: [String: Int]

    /// Reads the directory of the archive open as `fd`, a regular file. Takes ownership of `fd`:
    /// it is closed when the reader goes, or when this throws.
    public init(fileDescriptor fd: Int32) throws {
        let file = try ZipFile(fd: fd)
        (entries, isZip64) = try ZipDirectory.read(file)
        self.file = file
        byName = ZipDirectory.index(entries)
    }

    /// The file's length in bytes.
    public var size: Int { file.count }

    public func find(_ name: String) -> ZipEntry? { byName[name].map { entries[$0] } }

    /// Entry payload (decompressed), at most `max` bytes, CRC-checked.
    public func read(_ e: ZipEntry, max: Int) throws -> [UInt8] {
        try ZipDirectory.payload(e, max: max, size: file.count) { try file.bytes($0) }
    }

    public func read(named name: String, max: Int) throws -> [UInt8] {
        guard let e = find(name) else { throw ZipError.corrupt("missing `\(name)`") }
        return try read(e, max: max)
    }
}
