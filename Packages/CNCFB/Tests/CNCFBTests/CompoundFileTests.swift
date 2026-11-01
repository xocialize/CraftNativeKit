// CNCFB — the reader and writer against each other, against olefile's reading of every compound file in the
// legacy fixtures (and of PowerPoint's own protected copies, when that local set is there), and against damaged
// input: the hostile fixtures, deckcraft's 400 CFB parity inputs, and seeded mutations.
import CryptoKit
import CNTestSupport
import Foundation
import Testing
@testable import CNCFB

@Suite struct CompoundFileTests {
    static func data(_ n: Int, seed: UInt32) -> [UInt8] {
        var x = seed | 1
        return (0 ..< n).map { _ in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            return UInt8(truncatingIfNeeded: x)
        }
    }

    // MARK: Round trips

    @Test(arguments: [3, 4])
    func streamsOfEverySizeRoundTrip(version: Int) throws {
        let sizes = [0, 1, 63, 64, 65, 511, 512, 4095, 4096, 4097, 100_000]
        var w = CompoundFileWriter(version: version)
        for (i, n) in sizes.enumerated() { try w.addStream("s\(i)", Self.data(n, seed: UInt32(i))) }
        try w.addStream("Nested/Deeper/leaf", Self.data(3000, seed: 99))
        try w.addStorage("Empty")
        let f = try CompoundFile(try w.bytes())
        #expect(f.majorVersion == version)
        #expect(f.sectorSize == (version == 4 ? 4096 : 512))
        for (i, n) in sizes.enumerated() {
            #expect(try f.stream("s\(i)") == Self.data(n, seed: UInt32(i)), "stream of \(n) bytes")
            #expect(f.entry("s\(i)")?.size == UInt64(n))
        }
        #expect(try f.stream("nested/DEEPER/Leaf") == Self.data(3000, seed: 99))
        #expect(f.entry("Empty")?.kind == .storage)
        #expect(f.entry("Nested/Deeper")?.kind == .storage)
        #expect(f.children(of: f.root).map(\.name) == ["s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9",
                                                        "s10", "Empty", "Nested"])
        #expect(throws: CFBError.notFound("missing")) { try f.stream("missing") }
    }

    /// Over 109 FAT sectors the FAT's ids continue in DIFAT sectors.
    @Test func aLargeFileNeedsTheDIFAT() throws {
        var w = CompoundFileWriter()
        let big = Self.data(8 << 20, seed: 7)                    // 16,384 sectors: 129 FAT sectors
        try w.addStream("big", big)
        try w.addStream("small", [1, 2, 3])
        let bytes = try w.bytes()
        let difatSectors = UInt32(bytes[72]) | UInt32(bytes[73]) << 8
        #expect(difatSectors == 1)
        let f = try CompoundFile(bytes)
        #expect(try f.stream("big") == big)
        #expect(try f.stream("small") == [1, 2, 3])
    }

    @Test func classIDsAndEmptyFiles() throws {
        var w = CompoundFileWriter()
        let id = Array(1 ... 16).map(UInt8.init)
        try w.setRootCLSID(id)
        try w.addStorage("S", clsid: Array(repeating: 0xAB, count: 16))
        let f = try CompoundFile(try w.bytes())
        #expect(f.root.clsid == id)
        #expect(f.entry("S")?.clsid == Array(repeating: 0xAB, count: 16))
        #expect(try CompoundFile(try CompoundFileWriter().bytes()).entries.count == 1)
        #expect(throws: CFBError.invalid("a class id is 16 bytes")) { try w.setRootCLSID([1]) }
    }

    @Test func theWriterRefusesBadNames() {
        var w = CompoundFileWriter()
        #expect(throws: CFBError.self) { try w.addStream(String(repeating: "x", count: 32), []) }
        #expect(throws: CFBError.self) { try w.addStream("a:b", []) }
        #expect(throws: (any Error).self) {
            try w.addStream("Dup", [1])
            try w.addStream("DUP", [2])
        }
        #expect(throws: CFBError.invalid("x: x is a stream")) {
            var v = CompoundFileWriter()
            try v.addStream("x", [1])
            try v.addStream("x/y", [2])
        }
    }

    /// [MS-CFB] 2.6.4: shorter names first, then code unit by code unit, upper-cased.
    @Test func namesSortAsTheFormatSays() {
        #expect(CFBName.compare("B", "AA") < 0)
        #expect(CFBName.compare("abc", "ABD") < 0)
        #expect(CFBName.equal("EncryptionInfo", "encryptioninfo"))
        #expect(CFBName.equal("ä", "Ä"))
        #expect(!CFBName.equal("\u{6}DataSpaces", "DataSpaces"))
        #expect(CFBName.compare("🔑", "🔑") == 0)
    }

    // MARK: The fixtures, against olefile

    struct Listing: Decodable {
        struct Item: Decodable { let path: String; let kind: String; let size: Int?; let sha256: String? }
        let sectorSize: Int
        let entries: [Item]
    }

    static func hex(_ b: [UInt8]) -> String { SHA256.hash(data: b).map { String(format: "%02x", $0) }.joined() }

    /// Our reading of `file` is olefile's: the same storages and streams, each stream's bytes the same.
    static func matchesOlefile(_ file: URL, _ listing: URL) throws {
        let ref = try JSONDecoder().decode(Listing.self, from: Data(contentsOf: listing))
        let f = try CompoundFile(Array(try Data(contentsOf: file)))
        #expect(f.sectorSize == ref.sectorSize, "\(file.lastPathComponent)")
        let ours = f.entries.dropFirst().map { $0.path.joined(separator: "/") }.sorted { $0.lowercased() < $1.lowercased() }
        #expect(ours == ref.entries.map(\.path), "\(file.lastPathComponent)")
        for item in ref.entries {
            let e = try #require(f.entry(item.path), "\(file.lastPathComponent): \(item.path)")
            #expect((e.kind == .stream ? "stream" : "storage") == item.kind)
            if e.kind == .stream {
                let bytes = try f.read(e)
                #expect(bytes.count == item.size, "\(file.lastPathComponent): \(item.path)")
                #expect(hex(bytes) == item.sha256, "\(file.lastPathComponent): \(item.path)")
            }
        }
    }

    static var legacy: URL { Fixtures.root.appending(path: "legacy", directoryHint: .isDirectory) }

    @Test func everyFixtureReadsAsOlefileReadsIt() throws {
        let refs = Self.legacy.appending(path: "reference")
        let listings = (try? FileManager.default.contentsOfDirectory(atPath: refs.path))?.filter { $0.hasSuffix(".olefile.json") } ?? []
        try #require(!listings.isEmpty, "no legacy fixtures (Tools/legacy/make-fixtures.sh)")
        var checked = 0
        for l in listings.sorted() {
            let name = String(l.dropLast(".olefile.json".count))
            let file = [Self.legacy.appending(path: "ppt/\(name)"), Self.legacy.appending(path: "encrypted/\(name)")]
                .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let file else { continue }
            try Self.matchesOlefile(file, refs.appending(path: l))
            checked += 1
        }
        #expect(checked == listings.count)
    }

    /// PowerPoint's own protected copies (local-only, Tools/legacy/powerpoint-protect.sh): version 4 files.
    @Test func powerPointsProtectedCopiesReadAsOlefileReadsThem() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/powerpoint-protected")
        let listings = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".olefile.json") } ?? []
        guard !listings.isEmpty else { return }                // the local set isn't on this Mac
        for l in listings {
            try Self.matchesOlefile(dir.appending(path: String(l.dropLast(".olefile.json".count))), dir.appending(path: l))
        }
    }

    // MARK: Damaged input never traps or hangs

    /// Reads everything `bytes` claims to hold; any error is fine, a trap or a hang isn't.
    static func readAll(_ bytes: [UInt8]) {
        guard let f = try? CompoundFile(bytes) else { return }
        for e in f.entries where e.kind == .stream { _ = try? f.read(e) }
    }

    @Test func theHostileFixturesFailCleanly() throws {
        let dir = Self.legacy.appending(path: "hostile")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { !$0.hasSuffix(".meta.json") } ?? []
        try #require(!names.isEmpty, "no hostile fixtures (Tools/legacy/make-fixtures.sh)")
        for n in names { Self.readAll(Array(try Data(contentsOf: dir.appending(path: n)))) }
    }

    /// deckcraft's CFB parity inputs (pptx/modules.txt): small hand-made compound files, many malformed.
    @Test func deckcraftsCFBInputsFailCleanly() throws {
        let text = try? String(contentsOf: Fixtures.root.appending(path: "pptx/modules.txt"), encoding: .utf8)
        guard let text else { return }
        var n = 0
        for line in text.split(separator: "\n") where line.hasPrefix("cfb\t") {
            let fields = line.split(separator: "\t")
            guard fields.count > 1 else { continue }
            let hex = Array(fields[1].utf8)
            var b: [UInt8] = []
            var i = 0
            while i + 1 < hex.count {
                b.append(UInt8(String(decoding: hex[i ... i + 1], as: UTF8.self), radix: 16) ?? 0)
                i += 2
            }
            Self.readAll(b)
            n += 1
        }
        #expect(n == 400)
    }

    @Test(arguments: [3, 4])
    func seededMutationsFailCleanly(version: Int) throws {
        var w = CompoundFileWriter(version: version)
        try w.addStream("EncryptionInfo", Self.data(300, seed: 1))
        try w.addStream("EncryptedPackage", Self.data(9000, seed: 2))
        try w.addStream("\u{6}DataSpaces/DataSpaceMap", Self.data(112, seed: 3))
        let good = try w.bytes()
        var rng = UInt64(0x2026_1030)
        func next() -> Int {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: rng >> 33)
        }
        for _ in 0 ..< 3000 {
            var b = good
            for _ in 0 ..< 1 + next() % 8 {
                let at = next() % (next() % 4 == 0 ? b.count : min(b.count, 2048))
                b[at] = UInt8(truncatingIfNeeded: next())
            }
            if next() % 5 == 0 { b.removeLast(next() % b.count) }
            Self.readAll(b)
        }
    }

    /// With `CNCFB_WRITE_DIR` set, writes files for other readers to check (Tools/legacy/check-cfb-writer.sh runs
    /// olefile and Apache POI over them): each `<name>.cfb` with `<name>.expected.json`, olefile-list's shape.
    @Test func writeFilesForOtherReaders() throws {
        guard let dir = ProcessInfo.processInfo.environment["CNCFB_WRITE_DIR"], !dir.isEmpty else { return }
        let out = URL(filePath: dir, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cases: [(String, Int, [(String, Int)])] = [
            ("v3-small", 3, [("a", 10), ("b", 0), ("Storage/c", 4095)]),
            ("v3-mixed", 3, [("EncryptionInfo", 300), ("EncryptedPackage", 40_000), ("\u{6}DataSpaces/Version", 76),
                             ("\u{6}DataSpaces/DataSpaceInfo/StrongEncryptionDataSpace", 64), ("Ünïcödé 🔑", 5000)]),
            ("v3-difat", 3, [("big", 8 << 20), ("tiny", 1)]),
            ("v4-mixed", 4, [("EncryptionInfo", 300), ("EncryptedPackage", 40_000), ("Deep/er/est", 4096)]),
            ("v3-many", 3, (0 ..< 300).map { ("Storage\($0 % 7)/stream\($0)", $0 * 37) }),
        ]
        for (name, version, streams) in cases {
            var w = CompoundFileWriter(version: version)
            var rows: [[String: Any]] = []
            var storages = Set<String>()
            for (i, (path, size)) in streams.enumerated() {
                let d = Self.data(size, seed: UInt32(i + 1))
                try w.addStream(path, d)
                rows.append(["path": path, "kind": "stream", "size": size, "sha256": Self.hex(d)])
                var parts = path.split(separator: "/").dropLast().map(String.init)
                while !parts.isEmpty { storages.insert(parts.joined(separator: "/")); parts.removeLast() }
            }
            rows += storages.map { ["path": $0, "kind": "storage"] }
            try Data(try w.bytes()).write(to: out.appending(path: "\(name).cfb"))
            let json = try JSONSerialization.data(withJSONObject: ["entries": rows], options: [.sortedKeys])
            try json.write(to: out.appending(path: "\(name).expected.json"))
        }
    }

    @Test func notACompoundFile() {
        #expect(throws: CFBError.notCompoundFile) { try CompoundFile(Array("PK\u{3}\u{4}".utf8)) }
        #expect(throws: CFBError.notCompoundFile) { try CompoundFile(CompoundFile.signature) }
        #expect(!CompoundFile.isCompoundFile([0xD0, 0xCF]))
    }
}
