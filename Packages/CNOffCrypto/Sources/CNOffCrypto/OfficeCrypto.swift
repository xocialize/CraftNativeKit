// CNOffCrypto — opening password-protected OOXML ([MS-OFFCRYPTO] v20260217): the compound file holding
// `EncryptionInfo` and `EncryptedPackage` (CNCFB) is checked against a password and decrypted back to the zip it
// wraps. Agile encryption (Office 2010 and later; PowerPoint 16 writes AES-256, SHA-512, 100,000 rounds) and
// Standard encryption (Office 2007; AES in ECB mode, SHA-1) are read. Extensible encryption and rights-managed
// (IRM) files are recognised and refused by name. Written from the specification (Docs/plans/
// Legacy-PPT-and-Encryption.md §1); deckcraft has no decryption. The primitives are CommonCrypto's.
//
// Every value comes from the file: sizes, counts and the spin count are bounded before use (the specification caps
// the spin count at 10,000,000), the key derivation can be cancelled, and nothing here traps. Passwords and keys
// are never logged or put into errors.
import CNCFB
import Foundation

public enum OfficeCrypto {
    /// What protects a file.
    public enum Method: Sendable, Equatable, CustomStringConvertible {
        /// Agile encryption: the cipher (AES), its key length in bits, the hash and the password's spin count.
        case agile(cipher: String, keyBits: Int, hash: String, spinCount: Int)
        /// Standard encryption: AES in ECB mode with SHA-1; the key length in bits.
        case standard(keyBits: Int)

        public var description: String {
            switch self {
            case let .agile(c, k, h, n): "Agile \(c)-\(k), \(h), \(n) rounds"
            case let .standard(k): "Standard AES-\(k), SHA-1"
            }
        }
    }

    /// The `EncryptionInfo` and `EncryptedPackage` streams of a protected OOXML file, or nil when `bytes` isn't one.
    /// Throws for a protected file this reader can't open (Extensible encryption, IRM).
    public static func protectedPackage(_ bytes: [UInt8]) throws(OfficeCryptoError) -> ProtectedPackage? {
        guard CompoundFile.isCompoundFile(bytes) else { return nil }
        let cfb: CompoundFile
        do { cfb = try CompoundFile(bytes) } catch { return nil }
        if cfb.contains("\u{9}DRMContent") || cfb.contains("\u{6}DataSpaces/TransformInfo/DRMEncryptedTransform") {
            throw .rightsManaged
        }
        guard cfb.contains("EncryptionInfo"), cfb.contains("EncryptedPackage") else { return nil }
        do {
            return try ProtectedPackage(info: try cfb.stream("EncryptionInfo"), package: try cfb.stream("EncryptedPackage"))
        } catch let e as OfficeCryptoError {
            throw e
        } catch {
            throw .damaged("\(error)")
        }
    }

    /// The zip inside a protected OOXML file, with its password. `isCancelled` is polled during the key derivation.
    public static func decrypt(_ bytes: [UInt8], password: String,
                               isCancelled: @Sendable () -> Bool = { false }) throws(OfficeCryptoError) -> [UInt8] {
        guard let p = try protectedPackage(bytes) else { throw .notEncrypted }
        return try p.decrypt(password: password, isCancelled: isCancelled)
    }
}

/// A protected OOXML file's two streams, parsed.
public struct ProtectedPackage: Sendable {
    public let method: OfficeCrypto.Method
    let info: EncryptionInfo
    /// The whole `EncryptedPackage` stream: an 8-byte size, then the ciphertext.
    let package: [UInt8]

    public init(info bytes: [UInt8], package: [UInt8]) throws(OfficeCryptoError) {
        info = try EncryptionInfo.parse(bytes)
        method = info.method
        self.package = package
        guard package.count >= 8 else { throw .damaged("the encrypted package is shorter than its size field") }
    }

    /// The zip, or `wrongPassword`.
    public func decrypt(password: String, isCancelled: @Sendable () -> Bool = { false }) throws(OfficeCryptoError) -> [UInt8] {
        let pw = Array(password.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        switch info {
        case let .agile(a): return try a.decrypt(pw, package, isCancelled)
        case let .standard(s): return try s.decrypt(pw, package, isCancelled)
        }
    }
}

public enum OfficeCryptoError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not a protected OOXML file.
    case notEncrypted
    /// The password doesn't open it.
    case wrongPassword
    /// Protected in a way this reader doesn't handle (Extensible encryption, an unknown cipher or hash).
    case unsupported(String)
    /// Rights-managed (IRM): opening needs a rights-management licence.
    case rightsManaged
    /// The encryption data is malformed, or the package fails its integrity check.
    case damaged(String)
    /// The caller cancelled.
    case cancelled

    public var description: String {
        switch self {
        case .notEncrypted: "not a password-protected file"
        case .wrongPassword: "the password is incorrect"
        case let .unsupported(m): "protected in a way DeckCraft can't open (\(m))"
        case .rightsManaged: "protected with rights management (IRM), which DeckCraft can't open"
        case let .damaged(m): "the protected file is damaged: \(m)"
        case .cancelled: "cancelled"
        }
    }
}

// MARK: - EncryptionInfo

enum EncryptionInfo: Sendable {
    case agile(Agile)
    case standard(Standard)

    var method: OfficeCrypto.Method {
        switch self {
        case let .agile(a): .agile(cipher: a.cipher, keyBits: a.encryptor.keyBits, hash: a.encryptor.hash.name, spinCount: a.encryptor.spinCount)
        case let .standard(s): .standard(keyBits: s.keyBits)
        }
    }

    static func parse(_ b: [UInt8]) throws(OfficeCryptoError) -> EncryptionInfo {
        guard b.count >= 8 else { throw .damaged("EncryptionInfo is too short") }
        let major = le16(b, 0), minor = le16(b, 2)
        switch (major, minor) {
        case (4, 4): return .agile(try Agile.parse(Array(b[8...])))
        case (2, 2), (3, 2), (4, 2): return .standard(try Standard.parse(b))
        case (3, 3), (4, 3): throw .unsupported("Extensible encryption")
        default: throw .unsupported("EncryptionInfo version \(major).\(minor)")
        }
    }
}

// MARK: Agile ([MS-OFFCRYPTO] 2.3.4.10–2.3.4.15)

struct Agile: Sendable {
    struct Encryptor: Sendable {
        var hash: Hash
        var keyBits: Int
        var blockSize: Int
        var spinCount: Int
        var salt: [UInt8]
        var verifierInput: [UInt8]
        var verifierValue: [UInt8]
        var keyValue: [UInt8]
    }

    var cipher: String
    var keyBits: Int
    var blockSize: Int
    var hash: Hash
    var salt: [UInt8]
    var hmacKey: [UInt8]?
    var hmacValue: [UInt8]?
    var encryptor: Encryptor

    static let maxSpinCount = 10_000_000
    static let verifierInputBlock: [UInt8] = [0xFE, 0xA7, 0xD2, 0x76, 0x3B, 0x4B, 0x9E, 0x79]
    static let verifierValueBlock: [UInt8] = [0xD7, 0xAA, 0x0F, 0x6D, 0x30, 0x61, 0x34, 0x4E]
    static let keyValueBlock: [UInt8] = [0x14, 0x6E, 0x0B, 0xE7, 0xAB, 0xAC, 0xD0, 0xD6]
    static let hmacKeyBlock: [UInt8] = [0x5F, 0xB2, 0xAD, 0x01, 0x0C, 0xB9, 0xE1, 0xF6]
    static let hmacValueBlock: [UInt8] = [0xA0, 0x67, 0x7F, 0x02, 0xB2, 0x2C, 0x84, 0x33]
    static let segment = 4096

    static func parse(_ xml: [UInt8]) throws(OfficeCryptoError) -> Agile {
        let doc = AgileXML()
        let parser = XMLParser(data: Data(xml))
        parser.shouldProcessNamespaces = true
        parser.delegate = doc
        guard parser.parse(), let kd = doc.keyData else { throw .damaged("the Agile encryption descriptor can't be read") }
        guard let pe = doc.passwordEncryptor else { throw .unsupported("no password key encryptor (certificate only)") }

        func int(_ d: [String: String], _ k: String) throws(OfficeCryptoError) -> Int {
            guard let v = d[k].flatMap({ Int($0) }) else { throw .damaged("\(k) is missing") }
            return v
        }
        func bytes(_ d: [String: String], _ k: String) throws(OfficeCryptoError) -> [UInt8] {
            guard let v = d[k], let data = Data(base64Encoded: v) else { throw .damaged("\(k) is missing") }
            return [UInt8](data)
        }
        func check(_ d: [String: String]) throws(OfficeCryptoError) -> (Hash, Int, Int) {
            guard d["cipherAlgorithm"] == "AES" else { throw .unsupported("cipher \(d["cipherAlgorithm"] ?? "none")") }
            guard d["cipherChaining"] == "ChainingModeCBC" else {
                throw .unsupported("chaining \(d["cipherChaining"] ?? "none")")
            }
            guard let h = Hash(d["hashAlgorithm"] ?? "") else { throw .unsupported("hash \(d["hashAlgorithm"] ?? "none")") }
            let bits = try int(d, "keyBits"), block = try int(d, "blockSize")
            guard [128, 192, 256].contains(bits), block == 16 else { throw .unsupported("AES-\(bits), block \(block)") }
            return (h, bits, block)
        }
        let (hash, bits, block) = try check(kd)
        let (pHash, pBits, pBlock) = try check(pe)
        let spin = try int(pe, "spinCount")
        guard (0 ... maxSpinCount).contains(spin) else { throw .damaged("spin count \(spin)") }
        let salt = try bytes(kd, "saltValue")
        guard (1 ... 65536).contains(salt.count) else { throw .damaged("salt size \(salt.count)") }
        var hmacKey: [UInt8]?, hmacValue: [UInt8]?
        if let di = doc.dataIntegrity {
            hmacKey = try bytes(di, "encryptedHmacKey")
            hmacValue = try bytes(di, "encryptedHmacValue")
        }
        return Agile(cipher: "AES", keyBits: bits, blockSize: block, hash: hash, salt: salt, hmacKey: hmacKey, hmacValue: hmacValue,
                     encryptor: Encryptor(hash: pHash, keyBits: pBits, blockSize: pBlock, spinCount: spin,
                                          salt: try bytes(pe, "saltValue"),
                                          verifierInput: try bytes(pe, "encryptedVerifierHashInput"),
                                          verifierValue: try bytes(pe, "encryptedVerifierHashValue"),
                                          keyValue: try bytes(pe, "encryptedKeyValue")))
    }

    /// The hash of salt + password, iterated `spinCount` times ([MS-OFFCRYPTO] 2.3.4.11).
    static func iterated(_ h: Hash, _ salt: [UInt8], _ pw: [UInt8], _ spin: Int,
                         _ isCancelled: () -> Bool) throws(OfficeCryptoError) -> [UInt8] {
        var hn = h.digest(salt + pw)
        var buf = [UInt8](repeating: 0, count: 4 + hn.count)
        for i in 0 ..< spin {
            if i % 16384 == 0, isCancelled() { throw .cancelled }
            buf[0] = UInt8(truncatingIfNeeded: i)
            buf[1] = UInt8(truncatingIfNeeded: i >> 8)
            buf[2] = UInt8(truncatingIfNeeded: i >> 16)
            buf[3] = UInt8(truncatingIfNeeded: i >> 24)
            buf.replaceSubrange(4..., with: hn)
            hn = h.digest(buf)
        }
        return hn
    }

    /// A key from the iterated hash and a block key: hashed, then cut or padded with 0x36 to the key length.
    static func key(_ h: Hash, _ hn: [UInt8], _ block: [UInt8], bits: Int) -> [UInt8] {
        fit(h.digest(hn + block), bits / 8, pad: 0x36)
    }

    static func fit(_ b: [UInt8], _ n: Int, pad: UInt8) -> [UInt8] {
        b.count >= n ? Array(b.prefix(n)) : b + [UInt8](repeating: pad, count: n - b.count)
    }

    func decrypt(_ pw: [UInt8], _ package: [UInt8], _ isCancelled: () -> Bool) throws(OfficeCryptoError) -> [UInt8] {
        let e = encryptor
        let hn = try Self.iterated(e.hash, e.salt, pw, e.spinCount, isCancelled)
        let iv = Self.fit(e.salt, e.blockSize, pad: 0x36)
        let input = try AES.cbc(Self.key(e.hash, hn, Self.verifierInputBlock, bits: e.keyBits), iv, e.verifierInput)
        let value = try AES.cbc(Self.key(e.hash, hn, Self.verifierValueBlock, bits: e.keyBits), iv, e.verifierValue)
        let hashed = e.hash.digest(Array(input.prefix(e.salt.count)))
        guard value.count >= hashed.count, Array(value.prefix(hashed.count)) == hashed else { throw .wrongPassword }
        let secret = Array(try AES.cbc(Self.key(e.hash, hn, Self.keyValueBlock, bits: e.keyBits), iv, e.keyValue).prefix(keyBits / 8))
        guard secret.count == keyBits / 8 else { throw .damaged("the key is too short") }

        // The integrity check, over the whole EncryptedPackage stream, before anything is decrypted.
        if let hmacKey, let hmacValue {
            let k = try AES.cbc(secret, Self.fit(hash.digest(salt + Self.hmacKeyBlock), blockSize, pad: 0x36), hmacKey)
            let v = try AES.cbc(secret, Self.fit(hash.digest(salt + Self.hmacValueBlock), blockSize, pad: 0x36), hmacValue)
            let n = hash.size
            guard k.count >= n, v.count >= n, hash.hmac(Array(k.prefix(n)), package) == Array(v.prefix(n)) else {
                throw .damaged("it fails its integrity check")
            }
        }

        let size = le64(package, 0)
        let body = package[8...]
        guard size <= UInt64(body.count) else { throw .damaged("the package claims \(size) bytes, more than it holds") }
        var out: [UInt8] = []
        out.reserveCapacity(Int(size))
        var index: UInt32 = 0
        var at = body.startIndex
        while at < body.endIndex, UInt64(out.count) < size {
            let end = min(at + Self.segment, body.endIndex)
            let chunk = Array(body[at ..< end])
            let usable = chunk.count - chunk.count % blockSize
            guard usable > 0 else { break }
            let iv = Self.fit(hash.digest(salt + le32(index)), blockSize, pad: 0x36)
            out += try AES.cbc(secret, iv, Array(chunk.prefix(usable)))
            at = end
            index &+= 1
        }
        guard UInt64(out.count) >= size else { throw .damaged("the package is shorter than its size") }
        out.removeLast(out.count - Int(size))
        return out
    }
}

/// The Agile descriptor's three elements, by local name (writers use different namespace prefixes).
final class AgileXML: NSObject, XMLParserDelegate {
    var keyData: [String: String]?
    var dataIntegrity: [String: String]?
    var passwordEncryptor: [String: String]?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "keyData": if keyData == nil { keyData = attributes }
        case "dataIntegrity": if dataIntegrity == nil { dataIntegrity = attributes }
        case "encryptedKey":
            if namespaceURI == "http://schemas.microsoft.com/office/2006/keyEncryptor/password", passwordEncryptor == nil {
                passwordEncryptor = attributes
            }
        default: break
        }
    }
}

// MARK: Standard ([MS-OFFCRYPTO] 2.3.4.5–2.3.4.9)

struct Standard: Sendable {
    var keyBits: Int
    var salt: [UInt8]
    var verifier: [UInt8]
    var verifierHashSize: Int
    var verifierHash: [UInt8]

    static let spinCount = 50_000

    static func parse(_ b: [UInt8]) throws(OfficeCryptoError) -> Standard {
        // Version (4), flags (4), header size (4), then the header and the verifier.
        let headerSize = Int(le32(b, 8))
        guard headerSize >= 32, b.count >= 12 + headerSize + 4 + 16 + 16 + 4 + 32 else {
            throw .damaged("the Standard encryption header is too short")
        }
        let h = 12
        let algID = le32(b, h + 8), hashID = le32(b, h + 12), keyBits = Int(le32(b, h + 16))
        guard [0x660E, 0x660F, 0x6610].contains(algID) else { throw .unsupported(String(format: "algorithm 0x%04X", algID)) }
        guard hashID == 0x8004 || hashID == 0 else { throw .unsupported(String(format: "hash 0x%04X", hashID)) }
        guard [128, 192, 256].contains(keyBits) else { throw .unsupported("AES-\(keyBits)") }
        var v = h + headerSize
        let saltSize = Int(le32(b, v))
        guard saltSize == 16 else { throw .damaged("salt size \(saltSize)") }
        v += 4
        let salt = Array(b[v ..< v + 16]), verifier = Array(b[v + 16 ..< v + 32])
        let hashSize = Int(le32(b, v + 32))
        guard hashSize == 20 else { throw .damaged("verifier hash size \(hashSize)") }
        return Standard(keyBits: keyBits, salt: salt, verifier: verifier, verifierHashSize: hashSize,
                        verifierHash: Array(b[v + 36 ..< v + 68]))
    }

    /// The key ([MS-OFFCRYPTO] 2.3.4.7): SHA-1 iterated 50,000 times, block 0, then CryptDeriveKey's two pads.
    func key(_ pw: [UInt8], _ isCancelled: () -> Bool) throws(OfficeCryptoError) -> [UInt8] {
        let h = Hash.sha1
        let hn = try Agile.iterated(h, salt, pw, Self.spinCount, isCancelled)
        let final = h.digest(hn + le32(0))
        var x1 = [UInt8](repeating: 0x36, count: 64), x2 = [UInt8](repeating: 0x5C, count: 64)
        for (i, b) in final.enumerated() {
            x1[i] ^= b
            x2[i] ^= b
        }
        return Array((h.digest(x1) + h.digest(x2)).prefix(keyBits / 8))
    }

    func decrypt(_ pw: [UInt8], _ package: [UInt8], _ isCancelled: () -> Bool) throws(OfficeCryptoError) -> [UInt8] {
        let k = try key(pw, isCancelled)
        let v = try AES.ecb(k, verifier)
        let vh = try AES.ecb(k, verifierHash)
        guard Hash.sha1.digest(v) == Array(vh.prefix(verifierHashSize)) else { throw .wrongPassword }
        let size = le64(package, 0)
        let body = Array(package[8...])
        let usable = body.count - body.count % 16
        guard size <= UInt64(usable) else { throw .damaged("the package claims \(size) bytes, more than it holds") }
        var out = try AES.ecb(k, Array(body.prefix(usable)))
        out.removeLast(out.count - Int(size))
        return out
    }
}

// MARK: - Little-endian reads (bounded: a short read is 0)

func le16(_ b: [UInt8], _ at: Int) -> UInt16 {
    guard at >= 0, at + 2 <= b.count else { return 0 }
    return UInt16(b[at]) | UInt16(b[at + 1]) << 8
}

func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
    guard at >= 0, at + 4 <= b.count else { return 0 }
    return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
}

func le64(_ b: [UInt8], _ at: Int) -> UInt64 { UInt64(le32(b, at)) | UInt64(le32(b, at + 4)) << 32 }

func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
