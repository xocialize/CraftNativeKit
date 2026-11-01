// CNZip — copied from PhotoCraftNative (Packages/PCIO/Tests/*/ZipTests.swift at 7fa4dcc), errors renamed.
// Tests ported from photocraft-format (crates/format/src/zip.rs), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors; plus deflate/zlib/gzip round trips.

import Foundation
import Synchronization
import Testing
@testable import CNZip

@Suite struct ZipTests {
    @Test func crcKnownValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func roundtrip() throws {
        var w = ZipWriter()
        try w.add("a.txt", Array("hello".utf8))
        try w.add("dir/b.bin", [0, 1, 2, 3])
        try w.add("empty", [])
        let bytes = try w.finish()
        let r = try ZipReader(bytes)
        #expect(r.entries.count == 3)
        #expect(try r.read(named: "a.txt", max: 100) == Array("hello".utf8))
        #expect(try r.read(named: "dir/b.bin", max: 100) == [0, 1, 2, 3])
        #expect(try r.read(named: "empty", max: 0).isEmpty)
        #expect(throws: ZipError.limitExceeded("zip entry `a.txt` is 5 bytes (max 3)")) { try r.read(named: "a.txt", max: 3) }
    }

    @Test func crcMatchesBitwiseReference() {
        func reference(_ data: ArraySlice<UInt8>) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in data {
                c ^= UInt32(b)
                for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            }
            return ~c
        }
        let data: [UInt8] = (0 ..< 1000).map { UInt8(truncatingIfNeeded: (UInt32($0) &* 2_654_435_761) >> 13) }
        for len in [0, 1, 7, 15, 16, 17, 63, 64, 65, 255, 256, 1000] {
            #expect(CRC32.checksum(Array(data[..<len])) == reference(data[..<len]))
        }
    }

    @Test func findLocatesEveryEntryInALargeArchive() throws {
        var w = ZipWriter()
        let n: UInt32 = 3000
        for i in 0 ..< n { try w.add(String(format: "tiles/%05d.zst", i), withUnsafeBytes(of: i.littleEndian) { Array($0) }) }
        let r = try ZipReader(try w.finish())
        #expect(r.entries.count == Int(n))
        for i in (0 ..< n).reversed() {
            let name = String(format: "tiles/%05d.zst", i)
            let e = try #require(r.find(name))
            #expect(e.name == name)
            #expect(try r.read(e, max: 4) == withUnsafeBytes(of: i.littleEndian) { Array($0) })
        }
        #expect(r.find("tiles/missing.zst") == nil)
        #expect(r.find("") == nil)
    }

    @Test func duplicateNamesResolveToTheFirstEntry() throws {
        var w = ZipWriter()
        try w.add("a", Array("first".utf8))
        try w.add("b", Array("other".utf8))
        try w.add("a", Array("second".utf8))
        let r = try ZipReader(try w.finish())
        #expect(r.entries.count == 3)
        #expect(try r.read(named: "a", max: 100) == Array("first".utf8))
        #expect(try r.read(named: "b", max: 100) == Array("other".utf8))
    }

    @Test func crcMismatchDetected() throws {
        var w = ZipWriter()
        try w.add("a", Array("hello".utf8))
        var bytes = try w.finish()
        let pos = try #require((0 ..< bytes.count - 5).first { Array(bytes[$0 ..< $0 + 5]) == Array("hello".utf8) })
        bytes[pos] = UInt8(ascii: "j")
        let r = try ZipReader(bytes)
        #expect(throws: ZipError.self) { try r.read(named: "a", max: 100) }
    }

    @Test func deflatedEntryWithUnboundedLimitRoundTrips() throws {
        let content = Array("DEFLATE-compressed PhotoCraft project content, with a valid CRC.".utf8)
        let compressed = try Deflate.deflate(content)
        var writer = ZipWriter()
        try writer.add("manifest.json", compressed)
        var bytes = try writer.finish()
        let eocd = bytes.count - 22
        let central = try ZipReader.u32(bytes, eocd + 16)
        let crc = CRC32.checksum(content)
        func put16(_ at: Int, _ v: UInt16) { bytes[at] = UInt8(v & 0xFF); bytes[at + 1] = UInt8(v >> 8) }
        func put32(_ at: Int, _ v: UInt32) { for k in 0 ..< 4 { bytes[at + k] = UInt8(v >> (8 * UInt32(k)) & 0xFF) } }
        put16(8, 8); put32(14, crc); put32(22, UInt32(content.count))
        put16(central + 10, 8); put32(central + 16, crc); put32(central + 24, UInt32(content.count))
        let archive = try ZipReader(bytes)
        #expect(try archive.read(named: "manifest.json", max: .max) == content)
        #expect(try archive.read(named: "manifest.json", max: content.count) == content)
        #expect(throws: ZipError.self) { try archive.read(named: "manifest.json", max: content.count - 1) }
        // A forged 4 GiB size is rejected without allocating it.
        put32(22, UInt32.max); put32(central + 24, UInt32.max)
        let forged = try ZipReader(bytes)
        #expect(throws: ZipError.self) { try forged.read(named: "manifest.json", max: .max) }
    }

    @Test func anEntryFromAnotherArchiveIsAnErrorNotACrash() throws {
        var big = ZipWriter()
        try big.add("a", [UInt8](repeating: 7, count: 4096))
        let foreign = try ZipReader(try big.finish()).entries[0]
        var small = ZipWriter()
        try small.add("a", Array("x".utf8))
        let r = try ZipReader(try small.finish())
        #expect(throws: ZipError.self) { try r.read(foreign, max: .max) }
    }

    @Test func offsetAccessRejectsOverflow() {
        #expect(throws: ZipError.self) { try ZipReader.u16([], Int.max) }
        #expect(throws: ZipError.self) { try ZipReader.u32([], Int.max - 3) }
    }

    @Test func deflateZlibGzipRoundTrip() throws {
        let data: [UInt8] = (0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 * 7 / 13) }
        #expect(try Deflate.inflate(try Deflate.deflate(data)) == data)
        #expect(try Deflate.zlibInflate(try Deflate.zlibDeflate(data)) == data)
        #expect(try Deflate.gunzip(try Deflate.gzip(data)) == data)
        #expect(try Deflate.inflate(try Deflate.deflate([])) == [])
        #expect(throws: ZipError.self) { try Deflate.inflate(try Deflate.deflate(data), limit: 1000) }
        var bad = try Deflate.zlibDeflate(data)
        bad[bad.count - 1] ^= 1
        #expect(throws: ZipError.self) { try Deflate.zlibInflate(bad) }
        let truncated = Array(try Deflate.deflate(data).prefix(100))
        #expect(throws: ZipError.self) { try Deflate.inflate(truncated) }
    }

    @Test func storedAndDeflatedEntriesMix() throws {
        var w = ZipWriter()
        try w.add("mimetype", Array("image/openraster".utf8))
        try w.add("stack.xml", [UInt8](repeating: 65, count: 10_000), compress: true)
        let bytes = try w.finish()
        #expect(ZipReader.mimetype(bytes) == Array("image/openraster".utf8))
        let r = try ZipReader(bytes)
        #expect(r.find("stack.xml")?.method == 8)
        #expect(try r.read(named: "stack.xml", max: 10_000) == [UInt8](repeating: 65, count: 10_000))
    }
}

/// ZIP64 (`.pcraft` format 2): written only when an archive needs it, read from any writer.
@Suite struct Zip64Tests {
    static func entry(_ i: Int) -> (String, [UInt8]) { (String(format: "tiles/%06d.zst", i), withUnsafeBytes(of: UInt32(i).littleEndian) { Array($0) }) }

    static func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    static func le32(_ b: [UInt8], _ o: Int) -> Int { le16(b, o) | le16(b, o + 2) << 16 }

    /// An archive that fits stays byte for byte the classic layout (what photocraft writes and
    /// reads): version 2.0, no extra fields, no ZIP64 end records.
    @Test func classicArchiveKeepsTheClassicLayout() throws {
        var w = ZipWriter()
        try w.add("a", Array("hi".utf8))
        #expect(!w.usesZip64)
        let bytes = try w.finish()
        let crc = CRC32.checksum(Array("hi".utf8))
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16) }
        let local = u32(0x0403_4B50) + u16(20) + u16(0x0800) + u16(0) + u16(0) + u16(0x21) + u32(Int(crc)) + u32(2) + u32(2) + u16(1) + u16(0)
            + Array("a".utf8) + Array("hi".utf8)
        let central = u32(0x0201_4B50) + u16(20) + u16(20) + u16(0x0800) + u16(0) + u16(0) + u16(0x21) + u32(Int(crc)) + u32(2) + u32(2)
            + u16(1) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(0) + Array("a".utf8)
        let end = u32(0x0605_4B50) + u16(0) + u16(0) + u16(1) + u16(1) + u32(central.count) + u32(local.count) + u16(0)
        #expect(bytes == local + central + end)
        #expect(try !ZipReader(bytes).isZip64)
    }

    /// Every ZIP64 field written (forced) reads back: sizes and offsets from the extended
    /// information fields, counts from the ZIP64 end record.
    @Test func forcedZip64RoundTrips() throws {
        var w = ZipWriter(forceZip64: true)
        try w.add("manifest.json", Array("{}".utf8))
        try w.add("empty", [])
        try w.add("stack.xml", [UInt8](repeating: 65, count: 10_000), compress: true)
        try w.addStored("blob", [1, 2, 3], crc: CRC32.checksum([1, 2, 3]))
        #expect(w.usesZip64)
        let bytes = try w.finish()
        let r = try ZipReader(bytes)
        #expect(r.isZip64)
        #expect(r.entries.map(\.name) == ["manifest.json", "empty", "stack.xml", "blob"])
        #expect(try r.read(named: "manifest.json", max: 100) == Array("{}".utf8))
        #expect(try r.read(named: "empty", max: 0).isEmpty)
        #expect(r.find("stack.xml")?.method == 8)
        #expect(try r.read(named: "stack.xml", max: 10_000) == [UInt8](repeating: 65, count: 10_000))
        #expect(try r.read(named: "blob", max: 3) == [1, 2, 3])
        // The classic end record defers every field to ZIP64.
        let eocd = bytes.count - 22
        #expect(Self.le16(bytes, eocd + 10) == 0xFFFF)
        #expect(Self.le32(bytes, eocd + 12) == 0xFFFF_FFFF)
        #expect(Self.le32(bytes, eocd + 16) == 0xFFFF_FFFF)
        #expect(Self.le32(bytes, eocd - 20) == 0x0706_4B50, "the ZIP64 locator precedes the end record")
        // The first local header still names the manifest where `isPcraft` looks for it.
        #expect(Array(bytes[30 ..< 43]) == Array("manifest.json".utf8))
    }

    /// More than 65,535 entries: the count goes to the ZIP64 end record, offsets and sizes stay
    /// classic.
    @Test func entriesBeyondTheClassicCountUseZip64() throws {
        let n = 70_000
        var w = ZipWriter()
        var shapes: [(nameLength: Int, size: Int)] = []
        for i in 0 ..< n {
            let (name, data) = Self.entry(i)
            try w.add(name, data)
            shapes.append((name.utf8.count, data.count))
            if i == 65_533 { #expect(!w.usesZip64 && ZipWriter.fitsClassic(shapes)) }
        }
        #expect(w.usesZip64)
        #expect(!ZipWriter.fitsClassic(shapes))
        let bytes = try w.finish()
        #expect(Self.le16(bytes, bytes.count - 22 + 10) == 0xFFFF)
        let r = try ZipReader(bytes)
        #expect(r.isZip64)
        #expect(r.entries.count == n)
        for i in [0, 1, 65_534, 65_535, 65_536, n - 1] {
            let (name, data) = Self.entry(i)
            #expect(try r.read(named: name, max: 4) == data)
        }
    }

    @Test func fitsClassicAgreesWithTheWriter() throws {
        for count in [0, 1, 3, 100] {
            var w = ZipWriter()
            var shapes: [(nameLength: Int, size: Int)] = []
            for i in 0 ..< count {
                let (name, data) = Self.entry(i)
                try w.add(name, data)
                shapes.append((name.utf8.count, data.count))
            }
            #expect(ZipWriter.fitsClassic(shapes) == !w.usesZip64)
        }
        // Sizes and offsets at the sentinel or beyond need ZIP64, without allocating them.
        #expect(!ZipWriter.fitsClassic([(1, 0xFFFF_FFFF)]))
        #expect(ZipWriter.fitsClassic([(1, 0xFFFF_FFFF - 31 - 1 - 46 - 22)]))
        #expect(!ZipWriter.fitsClassic([(1, 0xFFFF_FFFF - 31), (1, 0)]), "the second entry's offset is the sentinel")
    }

    /// Four bytes that happen to match the locator's signature just before a classic end record
    /// (here: the last entry's name) don't turn a valid classic archive into an error.
    @Test func aLookalikeLocatorBeforeAClassicEndRecordIsIgnored() throws {
        var w = ZipWriter()
        try w.add("a", [1])
        // The central entry's name ends 20 bytes before the end record.
        let name = String(decoding: [0x50, 0x4B, 0x06, 0x07] + Array("0123456789abcdef".utf8), as: UTF8.self)
        try w.add(name, [2])
        let bytes = try w.finish()
        #expect(Self.le32(bytes, bytes.count - 22 - 20) == 0x0706_4B50)
        let r = try ZipReader(bytes)
        #expect(!r.isZip64)
        #expect(try r.read(named: name, max: 1) == [2])
    }

    @Test func damagedZip64RecordsAreErrorsNotCrashes() throws {
        var w = ZipWriter(forceZip64: true)
        try w.add("a", Array("hello".utf8))
        let good = try w.finish()
        let locator = good.count - 22 - 20
        func put64(_ b: inout [UInt8], _ at: Int, _ v: UInt64) { for k in 0 ..< 8 { b[at + k] = UInt8(v >> (8 * UInt64(k)) & 0xFF) } }
        // The locator points past the end, at itself, or beyond Int.max.
        for target: UInt64 in [UInt64(good.count), UInt64(locator), .max, UInt64(Int.max) - 10] {
            var bad = good
            put64(&bad, locator + 8, target)
            #expect(throws: ZipError.self, "\(target)") { try ZipReader(bad) }
        }
        // No locator although the classic end record defers to one.
        var noLocator = good
        noLocator[locator] = 0
        #expect(throws: ZipError.self) { try ZipReader(noLocator) }
        // A central directory claiming 2^62 entries, or reaching past the ZIP64 record.
        let record = Int(good[locator + 8]) | Int(good[locator + 9]) << 8
        var many = good
        put64(&many, record + 32, 1 << 62)
        #expect(throws: ZipError.self) { try ZipReader(many) }
        var long = good
        put64(&long, record + 40, 1 << 20)
        #expect(throws: ZipError.self) { try ZipReader(long) }
        // An entry whose central header defers to a ZIP64 field it doesn't have: its sizes and
        // offset are then taken as 0xFFFFFFFF, which this archive doesn't reach.
        let central = Int(good[record + 48]) | Int(good[record + 49]) << 8
        var noExtra = good
        noExtra[central + 30] = 0
        noExtra[central + 31] = 0
        #expect(throws: ZipError.self) { try ZipReader(noExtra) }
        // A ZIP64 size beyond the archive.
        var huge = good
        let extra = central + 46 + 1 + 4
        put64(&huge, extra + 8, 1 << 40)
        #expect(throws: ZipError.self) { try ZipReader(huge) }
    }

    /// Info-ZIP agrees: `unzip -t` accepts our forced-ZIP64 archive, and we read the ZIP64
    /// archive `zip -fz` writes (a partial extended-information field: the uncompressed size only).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") && FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip")))
    func infoZipInterop() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip64-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func run(_ tool: String, _ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        var w = ZipWriter(forceZip64: true)
        try w.add("manifest.json", Array("{\"format_version\": 2}".utf8))
        try w.add("tiles/x.zst", [UInt8](repeating: 9, count: 1000))
        try Data(try w.finish()).write(to: dir.appendingPathComponent("ours.zip"))
        #expect(try run("/usr/bin/unzip", ["-tqq", "ours.zip"]) == 0)

        let payload = (0 ..< 5000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        try Data(payload).write(to: dir.appendingPathComponent("p.bin"))
        #expect(try run("/usr/bin/zip", ["-q", "-0", "-fz", "-X", "theirs.zip", "p.bin"]) == 0)
        let r = try ZipReader([UInt8](try Data(contentsOf: dir.appendingPathComponent("theirs.zip"))))
        #expect(r.isZip64)
        #expect(try r.read(named: "p.bin", max: payload.count) == payload)
    }
}

/// The streaming writer and the file reader (AB-T-0249): the same bytes and the same answers as
/// their in-memory counterparts.
@Suite struct ZipStreamingTests {
    /// The archives the parity checks run on: classic, forced ZIP64, and one with a DEFLATE entry.
    static func archives() throws -> [(String, [UInt8])] {
        var classic = ZipWriter()
        try classic.add("manifest.json", Array("{\"format_version\": 1}".utf8))
        try classic.add("tiles/a.zst", [UInt8](repeating: 3, count: 5000))
        try classic.add("empty", [])
        var forced = ZipWriter(forceZip64: true)
        try forced.add("manifest.json", Array("{}".utf8))
        try forced.addStored("blob", [1, 2, 3], crc: CRC32.checksum([1, 2, 3]))
        var deflated = ZipWriter()
        try deflated.add("mimetype", Array("image/openraster".utf8))
        try deflated.add("stack.xml", [UInt8](repeating: 65, count: 10_000), compress: true)
        return [("classic", try classic.finish()), ("forced", try forced.finish()), ("deflated", try deflated.finish())]
    }

    /// An archive in a temporary file, open for reading (the reader owns the descriptor).
    static func reader(_ bytes: [UInt8]) throws -> ZipFileReader {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zip-file-reader-\(UUID().uuidString).zip")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        try #require(fd >= 0)
        return try ZipFileReader(fileDescriptor: fd)
    }

    @Test(arguments: [false, true])
    func streamWriterWritesZipWriterBytes(forceZip64: Bool) throws {
        var memory = ZipWriter(forceZip64: forceZip64)
        var stream = ZipStreamWriter(ZipMemorySink(), forceZip64: forceZip64)
        for i in 0 ..< 200 {
            let (name, data) = Zip64Tests.entry(i)
            try memory.add(name, data)
            if i % 2 == 0 { try stream.add(name, data) } else { try stream.addStored(name, data, crc: CRC32.checksum(data)) }
            #expect(stream.size == memory.size)
        }
        #expect(stream.usesZip64 == memory.usesZip64)
        #expect(try stream.finish().bytes == memory.finish())
    }

    /// More than 65,535 entries: the stream writer switches to ZIP64 where `ZipWriter` does.
    @Test func streamWriterAgreesPastTheClassicCount() throws {
        var memory = ZipWriter()
        var stream = ZipStreamWriter(ZipMemorySink())
        for i in 0 ..< 66_000 {
            let (name, data) = Zip64Tests.entry(i)
            try memory.add(name, data)
            try stream.add(name, data)
            if i == 65_533 || i == 65_534 { #expect(stream.usesZip64 == memory.usesZip64) }
        }
        #expect(stream.usesZip64)
        #expect(try stream.finish().bytes == memory.finish())
    }

    /// A stored entry rewritten in place (a manifest whose version is only settled at the end):
    /// its local header's CRC, its bytes and its central directory entry all change, nothing else.
    @Test func replaceStoredRewritesOneEntryInPlace() throws {
        let v1 = Array("{\"format_version\": 1}".utf8), v2 = Array("{\"format_version\": 2}".utf8)
        var memory = ZipWriter()
        var stream = ZipStreamWriter(ZipMemorySink())
        for w in 0 ..< 2 {
            for (name, data) in [("manifest.json", v1), ("tiles/a.zst", [UInt8](repeating: 9, count: 100))] {
                if w == 0 { try memory.add(name, data) } else { try stream.add(name, data) }
            }
        }
        try memory.replaceStored(0, v2, crc: CRC32.checksum(v2))
        try stream.replaceStored(0, v2, crc: CRC32.checksum(v2))
        var direct = ZipWriter()
        try direct.add("manifest.json", v2)
        try direct.add("tiles/a.zst", [UInt8](repeating: 9, count: 100))
        let expected = try direct.finish()
        #expect(try memory.finish() == expected)
        #expect(try stream.finish().bytes == expected)
        #expect(try ZipReader(expected).read(named: "manifest.json", max: 100) == v2)
        // Only a stored entry, and only with as many bytes.
        var w = ZipWriter()
        try w.add("a", Array("hello".utf8))
        try w.add("b", [UInt8](repeating: 65, count: 1000), compress: true)
        #expect(throws: ZipError.self) { try w.replaceStored(0, Array("hi".utf8), crc: 0) }
        #expect(throws: ZipError.self) { try w.replaceStored(1, [UInt8](repeating: 66, count: 1000), crc: 0) }
        #expect(throws: ZipError.self) { try w.replaceStored(2, [], crc: 0) }
    }

    /// Part of a stored entry rewritten in place, its CRC given (AB-T-0328: a manifest's version digit, the rest of
    /// it no longer kept), at any index: the place is read back from the central directory, classic or ZIP64.
    @Test(arguments: [false, true]) func patchStoredRewritesPartOfAnEntry(_ forceZip64: Bool) throws {
        let entries: [(String, [UInt8])] = [("manifest.json", Array("{\"format_version\": 1, \"x\": 1}".utf8)),
                                            ("thumb.png", [UInt8](repeating: 3, count: 40)),
                                            ("tiles/a.zst", [UInt8](repeating: 9, count: 100))]
        for index in entries.indices {
            var stream = ZipStreamWriter(ZipMemorySink(), forceZip64: forceZip64)
            for (name, data) in entries { try stream.add(name, data) }
            var changed = entries
            changed[index].1[5] = 0x32
            try stream.patchStored(index, at: 5, [0x32], crc: CRC32.checksum(changed[index].1))
            var direct = ZipWriter(forceZip64: forceZip64)
            for (name, data) in changed { try direct.add(name, data) }
            #expect(try stream.finish().bytes == direct.finish(), "entry \(index)")
        }
        var w = ZipStreamWriter(ZipMemorySink())
        try w.add("a", Array("hello".utf8))
        #expect(throws: ZipError.self) { try w.patchStored(0, at: 4, [1, 2], crc: 0) }
        #expect(throws: ZipError.self) { try w.patchStored(1, at: 0, [1], crc: 0) }
    }

    @Test func fileReaderReadsWhatTheMemoryReaderReads() throws {
        for (label, bytes) in try Self.archives() {
            let memory = try ZipReader(bytes)
            let file = try Self.reader(bytes)
            #expect(file.entries == memory.entries, "\(label)")
            #expect(file.isZip64 == memory.isZip64, "\(label)")
            #expect(file.size == bytes.count)
            for e in memory.entries {
                #expect(try file.read(e, max: .max) == memory.read(e, max: .max), "\(label) \(e.name)")
                #expect(file.find(e.name) == memory.find(e.name))
            }
            #expect(file.find("missing") == nil)
            #expect(throws: ZipError.corrupt("missing `missing`")) { try file.read(named: "missing", max: 1) }
        }
        // Many entries, read from every core at once.
        var w = ZipWriter()
        for i in 0 ..< 3000 { let (name, data) = Zip64Tests.entry(i); try w.add(name, data) }
        let file = try Self.reader(try w.finish())
        let failures = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: 3000) { i in
            let (name, data) = Zip64Tests.entry(i)
            if (try? file.read(named: name, max: 4)) != data { failures.add(1, ordering: .relaxed) }
        }
        #expect(failures.load(ordering: .relaxed) == 0)
    }

    /// Damaged archives fail the same way from a file as from memory.
    @Test func fileReaderRejectsWhatTheMemoryReaderRejects() throws {
        var w = ZipWriter(forceZip64: true)
        try w.add("a", Array("hello".utf8))
        let good = try w.finish()
        let locator = good.count - 22 - 20
        let record = Int(good[locator + 8]) | Int(good[locator + 9]) << 8
        let central = Int(good[record + 48]) | Int(good[record + 49]) << 8
        func put64(_ b: inout [UInt8], _ at: Int, _ v: UInt64) { for k in 0 ..< 8 { b[at + k] = UInt8(v >> (8 * UInt64(k)) & 0xFF) } }
        var variants: [[UInt8]] = [[], Array(good.prefix(21)), Array(good.dropLast()), Array(good.dropFirst(4))]
        for (at, value): (Int, UInt64) in [(locator + 8, UInt64(good.count)), (locator + 8, .max), (record + 32, 1 << 62), (record + 40, 1 << 20),
                                           (central + 46 + 1 + 4 + 8, 1 << 40), (central + 46 + 1 + 4 + 16, UInt64(good.count))] {
            var bad = good
            put64(&bad, at, value)
            variants.append(bad)
        }
        var crc = good
        crc[30 + 1] ^= 1
        variants.append(crc)
        for (k, bytes) in variants.enumerated() {
            let fromMemory = Result { try ZipReader(bytes).read(named: "a", max: 100) }
            let fromFile = Result { try Self.reader(bytes).read(named: "a", max: 100) }
            switch (fromMemory, fromFile) {
            case let (.success(a), .success(b)): #expect(a == b, "variant \(k)")
            case let (.failure(a), .failure(b)): #expect("\(a)" == "\(b)", "variant \(k)")
            default: Issue.record("variant \(k): memory \(fromMemory), file \(fromFile)")
            }
        }
    }
}
