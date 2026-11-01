// CNOffCrypto — writing password-protected OOXML ([MS-OFFCRYPTO] v20260217, 2.3.4.10–2.3.4.15 and the data spaces
// of 2.1 and 2.3.4.1–2.3.4.3), as PowerPoint 16 does: Agile encryption with AES-256 in CBC mode, SHA-512, a
// 100,000-round password hash and the HMAC integrity check, in a version 4 compound file (CNCFB) holding
// `EncryptionInfo`, `EncryptedPackage` and the `\x06DataSpaces` storage. Every salt, the package key and the HMAC key
// are fresh random bytes for each save.
import CommonCrypto
import CNCFB

extension OfficeCrypto {
    /// The parameters of the files this writes.
    public static let writtenMethod = Method.agile(cipher: "AES", keyBits: 256, hash: "SHA512", spinCount: 100_000)

    /// A password-protected file holding `zip` (an OOXML package). `random` gives n random bytes (tests pass a seeded
    /// one); `isCancelled` is polled during the key derivation.
    public static func encrypt(_ zip: [UInt8], password: String,
                               random: (Int) -> [UInt8] = OfficeCrypto.secureRandom,
                               isCancelled: () -> Bool = { false }) throws(OfficeCryptoError) -> [UInt8] {
        let hash = Hash.sha512, keyBytes = 32, block = 16, saltSize = 16, spin = 100_000
        let pw = Array(password.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }

        // The package: its size, then 4096-byte segments, each AES-CBC with the package key and an IV from the key
        // data's salt and the segment's number. The last segment is padded with zeros to whole blocks.
        let secret = random(keyBytes), keySalt = random(saltSize)
        var package = le64(UInt64(zip.count))
        package.reserveCapacity(8 + zip.count + block)
        var index: UInt32 = 0
        var at = 0
        while at < zip.count {
            var chunk = Array(zip[at ..< min(at + Agile.segment, zip.count)])
            if chunk.count % block != 0 { chunk += [UInt8](repeating: 0, count: block - chunk.count % block) }
            let iv = Agile.fit(hash.digest(keySalt + le32(index)), block, pad: 0x36)
            package += try AES.encryptCBC(secret, iv, chunk)
            at += Agile.segment
            index &+= 1
        }

        // The integrity check: an HMAC of the whole EncryptedPackage stream, its key and value encrypted.
        let hmacKey = random(hash.size)
        let hmac = hash.hmac(hmacKey, package)
        let encHmacKey = try AES.encryptCBC(secret, Agile.fit(hash.digest(keySalt + Agile.hmacKeyBlock), block, pad: 0x36), hmacKey)
        let encHmacValue = try AES.encryptCBC(secret, Agile.fit(hash.digest(keySalt + Agile.hmacValueBlock), block, pad: 0x36), hmac)

        // The password key encryptor: the verifier and the package key, each under its own password-derived key.
        let salt = random(saltSize)
        let hn = try Agile.iterated(hash, salt, pw, spin, isCancelled)
        let iv = Agile.fit(salt, block, pad: 0x36)
        let verifier = random(saltSize)
        let encVerifierInput = try AES.encryptCBC(Agile.key(hash, hn, Agile.verifierInputBlock, bits: keyBytes * 8), iv, verifier)
        let encVerifierValue = try AES.encryptCBC(Agile.key(hash, hn, Agile.verifierValueBlock, bits: keyBytes * 8), iv, hash.digest(verifier))
        let encKey = try AES.encryptCBC(Agile.key(hash, hn, Agile.keyValueBlock, bits: keyBytes * 8), iv, secret)

        func b64(_ b: [UInt8]) -> String { Base64.encode(b) }
        let common = #"saltSize="\#(saltSize)" blockSize="\#(block)" keyBits="\#(keyBytes * 8)" hashSize="\#(hash.size)" cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" hashAlgorithm="SHA512""#
        let xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\r\n"
            + #"<encryption xmlns="http://schemas.microsoft.com/office/2006/encryption" xmlns:p="http://schemas.microsoft.com/office/2006/keyEncryptor/password" xmlns:c="http://schemas.microsoft.com/office/2006/keyEncryptor/certificate">"#
            + #"<keyData \#(common) saltValue="\#(b64(keySalt))"/>"#
            + #"<dataIntegrity encryptedHmacKey="\#(b64(encHmacKey))" encryptedHmacValue="\#(b64(encHmacValue))"/>"#
            + #"<keyEncryptors><keyEncryptor uri="http://schemas.microsoft.com/office/2006/keyEncryptor/password">"#
            + #"<p:encryptedKey spinCount="\#(spin)" \#(common) saltValue="\#(b64(salt))" encryptedVerifierHashInput="\#(b64(encVerifierInput))" encryptedVerifierHashValue="\#(b64(encVerifierValue))" encryptedKeyValue="\#(b64(encKey))"/>"#
            + "</keyEncryptor></keyEncryptors></encryption>"
        // Version 4.4 and the reserved flags 0x40 ([MS-OFFCRYPTO] 2.3.4.10).
        let info = [4, 0, 4, 0] + le32(0x40) + Array(xml.utf8)

        var w = CompoundFileWriter(version: 4)
        do {
            try w.addStream("\u{6}DataSpaces/Version", DataSpaces.version)
            try w.addStream("\u{6}DataSpaces/DataSpaceMap", DataSpaces.map)
            try w.addStream("\u{6}DataSpaces/DataSpaceInfo/StrongEncryptionDataSpace", DataSpaces.definition)
            try w.addStream("\u{6}DataSpaces/TransformInfo/StrongEncryptionTransform/\u{6}Primary", DataSpaces.primary)
            try w.addStream("EncryptionInfo", info)
            try w.addStream("EncryptedPackage", package)
            return try w.bytes()
        } catch {
            throw .damaged("\(error)")
        }
    }

    /// `n` bytes from the system's secure random generator.
    public static func secureRandom(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        let status = CCRandomGenerateBytes(&b, n)
        // CCRandomGenerateBytes doesn't fail on macOS; if it ever did, the zeros would still decrypt, but no file is
        // worth writing with predictable salts, so fall back to the arc4random generator.
        if status != kCCSuccess { for i in b.indices { b[i] = UInt8.random(in: 0 ... 255) } }
        return b
    }
}

/// The `\x06DataSpaces` streams of an Agile-encrypted package ([MS-OFFCRYPTO] 2.1.4–2.1.9, 2.3.4.1–2.3.4.3).
enum DataSpaces {
    /// UNICODE-LP-P4: a length, UTF-16LE without a terminator, padded to 4 bytes.
    static func unicode(_ s: String) -> [UInt8] {
        let data = Array(s.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        return le32(UInt32(data.count)) + data + [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
    }

    static let v1_0: [UInt8] = [1, 0, 0, 0]

    /// DataSpaceVersionInfo: "Microsoft.Container.DataSpaces", reader, updater and writer 1.0.
    static let version = unicode("Microsoft.Container.DataSpaces") + v1_0 + v1_0 + v1_0

    /// DataSpaceMap: one entry, the stream EncryptedPackage in StrongEncryptionDataSpace.
    static let map: [UInt8] = {
        let entry = le32(1) + le32(0) + unicode("EncryptedPackage") + unicode("StrongEncryptionDataSpace")
        return le32(8) + le32(1) + le32(UInt32(4 + entry.count)) + entry
    }()

    /// DataSpaceDefinition: one transform, StrongEncryptionTransform.
    static let definition = le32(8) + le32(1) + unicode("StrongEncryptionTransform")

    /// The transform: its TransformInfoHeader, then EncryptionTransformInfo. For Agile the name is the null string
    /// and the EncryptionInfo stream is authoritative; PowerPoint 16 (and Apache POI) write a block size of 0 there,
    /// and so does this.
    static let primary: [UInt8] = {
        let id = unicode("{FF9A3F03-56EF-4613-BDD5-5A41C1D07246}")
        let header = le32(UInt32(8 + id.count)) + le32(1) + id + unicode("Microsoft.Container.EncryptionTransform")
            + v1_0 + v1_0 + v1_0
        return header + le32(0) + le32(0) + le32(0) + le32(4)
    }()
}

/// Base64 without Foundation's line breaks.
enum Base64 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    static func encode(_ b: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((b.count + 2) / 3 * 4)
        var i = 0
        while i < b.count {
            let n = min(3, b.count - i)
            let v = UInt32(b[i]) << 16 | (n > 1 ? UInt32(b[i + 1]) << 8 : 0) | (n > 2 ? UInt32(b[i + 2]) : 0)
            out.append(alphabet[Int(v >> 18 & 63)])
            out.append(alphabet[Int(v >> 12 & 63)])
            out.append(n > 1 ? alphabet[Int(v >> 6 & 63)] : UInt8(ascii: "="))
            out.append(n > 2 ? alphabet[Int(v & 63)] : UInt8(ascii: "="))
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }
}

func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(truncatingIfNeeded: v)) + le32(UInt32(truncatingIfNeeded: v >> 32)) }
