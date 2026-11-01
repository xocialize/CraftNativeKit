// CNOffCrypto — every encrypted .pptx in the legacy fixtures (Apache POI's Agile and Standard, msoffcrypto-tool's
// Agile; passwords in ASCII, with accents, outside the BMP and at 255 characters) decrypts to the exact zip it was
// made from; PowerPoint's own protected copies (local only) decrypt to what msoffcrypto-tool gets; wrong passwords,
// tampering, damage and cancelling all fail cleanly.
import CryptoKit
import CNCFB
import CNTestSupport
import Foundation
import Testing
@testable import CNOffCrypto

@Suite struct OfficeCryptoTests {
    struct Manifest: Decodable {
        struct File: Decodable {
            let file: String
            let kind: String?
            let password: String?
            let plaintext: String?
        }
        let files: [File]
    }

    static var legacy: URL { Fixtures.root.appending(path: "legacy", directoryHint: .isDirectory) }

    static func encryptedFixtures() throws -> [Manifest.File] {
        let url = legacy.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try JSONDecoder().decode(Manifest.self, from: data).files.filter { $0.kind == "encrypted-pptx" }
    }

    static func bytes(_ rel: String) throws -> [UInt8] { Array(try Data(contentsOf: legacy.appending(path: rel))) }

    static func sha(_ b: [UInt8]) -> String { SHA256.hash(data: b).map { String(format: "%02x", $0) }.joined() }

    @Test func everyEncryptedFixtureDecryptsToItsPlaintext() throws {
        let files = try Self.encryptedFixtures()
        try #require(files.count >= 36, "no legacy fixtures (Tools/legacy/make-fixtures.sh)")
        var methods = Set<String>()
        for f in files {
            let password = try #require(f.password), plain = try #require(f.plaintext)
            let enc = try Self.bytes(f.file)
            let p = try #require(try OfficeCrypto.protectedPackage(enc), "\(f.file)")
            methods.insert(p.method.description)
            #expect(try p.decrypt(password: password) == Self.bytes(plain), "\(f.file)")
        }
        // Agile AES-256/SHA-512 (POI and msoffcrypto-tool), Agile AES-128/SHA-1, and Standard AES-128.
        #expect(methods == ["Agile AES-256, SHA512, 100000 rounds", "Agile AES-128, SHA1, 100000 rounds", "Standard AES-128, SHA-1"])
    }

    @Test func aWrongPasswordIsSaidSo() throws {
        let files = try Self.encryptedFixtures()
        try #require(!files.isEmpty, "no legacy fixtures")
        for f in files where f.file.contains("corpus-sample") {
            let enc = try Self.bytes(f.file)
            #expect(throws: OfficeCryptoError.wrongPassword, "\(f.file)") { try OfficeCrypto.decrypt(enc, password: "not it") }
            // Case matters: a password is its exact UTF-16.
            if let pw = f.password, pw.lowercased() != pw {
                #expect(throws: OfficeCryptoError.wrongPassword) { try OfficeCrypto.decrypt(enc, password: pw.lowercased()) }
            }
        }
    }

    /// PowerPoint 16's own files (Tools/legacy/powerpoint-protect.sh, kept local): Agile AES-256/SHA-512 in a
    /// version 4 compound file.
    @Test func powerPointsProtectedCopiesDecrypt() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/powerpoint-protected")
        let digests = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".plain.sha256") } ?? []
        guard !digests.isEmpty else { return }                  // the local set isn't on this Mac
        struct Meta: Decodable { let password: String }
        for d in digests {
            let name = String(d.dropLast(".plain.sha256".count))
            let file = dir.appending(path: name)
            let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: dir.appending(path: "\(name).meta.json")))
            let want = try String(contentsOf: dir.appending(path: d), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let enc = Array(try Data(contentsOf: file))
            let p = try #require(try OfficeCrypto.protectedPackage(enc))
            #expect(p.method == .agile(cipher: "AES", keyBits: 256, hash: "SHA512", spinCount: 100_000))
            let zip = try p.decrypt(password: meta.password)
            #expect(Self.sha(zip) == want, "\(name)")
            #expect(zip.starts(with: [0x50, 0x4B, 0x03, 0x04]))
            #expect(throws: OfficeCryptoError.wrongPassword) { try p.decrypt(password: meta.password + "x") }
        }
    }

    /// Agile's HMAC covers the whole EncryptedPackage stream: a changed byte fails the check, not the zip reader.
    @Test func tamperingFailsTheIntegrityCheck() throws {
        let f = try #require(try Self.encryptedFixtures().first { $0.file.hasSuffix("corpus-sample.poi-agile-aes256-sha512.pptx") },
                             "no legacy fixtures")
        let cfb = try CompoundFile(try Self.bytes(f.file))
        let info = try cfb.stream("EncryptionInfo")
        var package = try cfb.stream("EncryptedPackage")
        package[package.count / 2] ^= 0x01
        let p = try ProtectedPackage(info: info, package: package)
        #expect(throws: OfficeCryptoError.damaged("it fails its integrity check")) { try p.decrypt(password: f.password ?? "") }
    }

    @Test func cancellingStopsTheKeyDerivation() throws {
        let f = try #require(try Self.encryptedFixtures().first { $0.file.contains("agile") }, "no legacy fixtures")
        let enc = try Self.bytes(f.file)
        #expect(throws: OfficeCryptoError.cancelled) { try OfficeCrypto.decrypt(enc, password: f.password ?? "", isCancelled: { true }) }
    }

    @Test func filesThatArentProtected() throws {
        #expect(try OfficeCrypto.protectedPackage(Array("PK\u{3}\u{4}rest".utf8)) == nil)
        var w = CompoundFileWriter()
        try w.addStream("PowerPoint Document", [1, 2, 3])
        #expect(try OfficeCrypto.protectedPackage(try w.bytes()) == nil)
        #expect(throws: OfficeCryptoError.notEncrypted) { try OfficeCrypto.decrypt(Array("PK".utf8), password: "x") }
    }

    @Test func rightsManagedAndExtensibleFilesAreRefusedByName() throws {
        var irm = CompoundFileWriter()
        try irm.addStream("\u{9}DRMContent", [0])
        #expect(throws: OfficeCryptoError.rightsManaged) { try OfficeCrypto.protectedPackage(try irm.bytes()) }
        var ext = CompoundFileWriter()
        try ext.addStream("EncryptionInfo", [3, 0, 3, 0] + [UInt8](repeating: 0, count: 60))
        try ext.addStream("EncryptedPackage", [UInt8](repeating: 0, count: 24))
        #expect(throws: OfficeCryptoError.unsupported("Extensible encryption")) { try OfficeCrypto.protectedPackage(try ext.bytes()) }
    }

    // MARK: Writing

    /// What we write, our reader opens: the zip back, PowerPoint's parameters, a version 4 compound file.
    @Test func encryptedFilesRoundTrip() throws {
        for size in [0, 1, 15, 16, 4095, 4096, 4097, 100_000] {
            let zip = (0 ..< size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            for pw in ["Password1", "Tëst-pässwörd", "key-🔑-2026", String(repeating: "p", count: 255)] {
                let enc = try OfficeCrypto.encrypt(zip, password: pw)
                let p = try #require(try OfficeCrypto.protectedPackage(enc))
                #expect(p.method == OfficeCrypto.writtenMethod)
                #expect(try p.decrypt(password: pw) == zip, "\(size) bytes")
                #expect(throws: OfficeCryptoError.wrongPassword) { try p.decrypt(password: pw + "!") }
                #expect(try CompoundFile(enc).majorVersion == 4)
                if size > 4096 { break }
            }
        }
        // Fresh salts and keys each time: the same input never encrypts the same way twice.
        #expect(try OfficeCrypto.encrypt([1, 2, 3], password: "x") != OfficeCrypto.encrypt([1, 2, 3], password: "x"))
    }

    /// The data spaces are the specification's structures; Apache POI writes the same bytes.
    @Test func theDataSpacesMatchPOIs() throws {
        let f = try #require(try Self.encryptedFixtures().first { $0.file.hasSuffix("corpus-sample.poi-agile-aes256-sha512.pptx") },
                             "no legacy fixtures")
        let poi = try CompoundFile(try Self.bytes(f.file))
        let ours = try CompoundFile(try OfficeCrypto.encrypt([1, 2, 3], password: "x"))
        for s in ["\u{6}DataSpaces/Version", "\u{6}DataSpaces/DataSpaceMap", "\u{6}DataSpaces/DataSpaceInfo/StrongEncryptionDataSpace",
                  "\u{6}DataSpaces/TransformInfo/StrongEncryptionTransform/\u{6}Primary"] {
            #expect(try ours.stream(s) == poi.stream(s), "\(s)")
        }
    }

    /// With `CNOFFCRYPTO_WRITE_DIR` set, writes encrypted files for other readers to check
    /// (Tools/legacy/check-encrypt.sh runs msoffcrypto-tool and Apache POI over them): `<name>.pptx`, its
    /// `<name>.plain` and its `<name>.password`.
    @Test func writeFilesForOtherReaders() throws {
        guard let dir = ProcessInfo.processInfo.environment["CNOFFCRYPTO_WRITE_DIR"], !dir.isEmpty else { return }
        let out = URL(filePath: dir, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let plain = try Self.encryptedFixtures().compactMap(\.plaintext)
        var seen = Set<String>()
        let passwords = ["Password1", "Tëst-pässwörd", "key-🔑-2026", String(repeating: "p", count: 255)]
        for (i, rel) in plain.enumerated() where seen.insert(rel).inserted {
            let zip = try Self.bytes(rel)
            let pw = passwords[i % passwords.count]
            let name = URL(filePath: rel).deletingPathExtension().lastPathComponent
            try Data(try OfficeCrypto.encrypt(zip, password: pw)).write(to: out.appending(path: "\(name).pptx"))
            try Data(zip).write(to: out.appending(path: "\(name).plain"))
            try Data(pw.utf8).write(to: out.appending(path: "\(name).password"))
        }
    }

    /// The hostile fixtures, and seeded damage to each stream, end in an error or a result: never a trap or a hang.
    @Test func damagedInputFailsCleanly() throws {
        let dir = Self.legacy.appending(path: "hostile")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".pptx") } ?? []
        try #require(!names.isEmpty, "no hostile fixtures")
        for n in names {
            _ = try? OfficeCrypto.decrypt(Array(try Data(contentsOf: dir.appending(path: n))), password: "Password1")
        }
        let f = try #require(try Self.encryptedFixtures().first { $0.file.hasSuffix("corpus-sample.poi-agile-aes256-sha512.pptx") })
        let cfb = try CompoundFile(try Self.bytes(f.file))
        let info = try cfb.stream("EncryptionInfo"), package = try cfb.stream("EncryptedPackage")
        var rng = UInt64(20_261_030)
        func next() -> Int {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: rng >> 33)
        }
        for _ in 0 ..< 300 {
            var i = info, p = package
            if next() % 2 == 0 { i[next() % i.count] = UInt8(truncatingIfNeeded: next()) } else { p[next() % min(p.count, 64)] ^= 0xFF }
            if next() % 7 == 0 { i.removeLast(next() % i.count) }
            if let pp = try? ProtectedPackage(info: i, package: p) {
                _ = try? pp.decrypt(password: f.password ?? "", isCancelled: { false })
            }
        }
    }
}
