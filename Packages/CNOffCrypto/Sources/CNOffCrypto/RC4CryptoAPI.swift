// CNOffCrypto — RC4 CryptoAPI ([MS-OFFCRYPTO] 2.3.5), the only encryption a legacy `.ppt` uses ([MS-PPT] 2.3.7):
// the header and verifier in the `CryptSession10Container`, a key per block from SHA-1(SHA-1(salt + password) +
// block number), and RC4 over each block. A 40-bit key is padded with zeros to 128 bits. PowerPoint 2003 to 2007 SP1
// encrypted files with a default password when the user gave none ([MS-OFFCRYPTO] 2.4.2.3), so a reader tries it
// first. RC4 is CommonCrypto's.
import CommonCrypto

public struct RC4CryptoAPI: Sendable {
    /// The password PowerPoint 2003 to 2007 SP1 used when the user gave none.
    public static let defaultPassword = "/01Hannes Ruescher/01"

    let keyBits: Int
    let salt: [UInt8]
    let verifier: [UInt8]
    let verifierHash: [UInt8]

    /// The RC4 CryptoAPI header ([MS-OFFCRYPTO] 2.3.5.1): version, flags, header size, the EncryptionHeader, then
    /// the EncryptionVerifier.
    public init(header b: [UInt8]) throws(OfficeCryptoError) {
        guard b.count >= 12 else { throw .damaged("the RC4 CryptoAPI header is too short") }
        let major = le16(b, 0), minor = le16(b, 2)
        guard [2, 3, 4].contains(major), minor == 2 else { throw .unsupported("RC4 CryptoAPI version \(major).\(minor)") }
        let headerSize = Int(le32(b, 8))
        guard headerSize >= 32, b.count >= 12 + headerSize + 4 + 16 + 16 + 4 + 20 else {
            throw .damaged("the RC4 CryptoAPI header is too short")
        }
        let h = 12
        let algID = le32(b, h + 8), hashID = le32(b, h + 12)
        var bits = Int(le32(b, h + 16))
        guard algID == 0x6801 || algID == 0 else { throw .unsupported(String(format: "algorithm 0x%04X", algID)) }
        guard hashID == 0x8004 || hashID == 0 else { throw .unsupported(String(format: "hash 0x%04X", hashID)) }
        if bits == 0 { bits = 40 }
        guard (40 ... 128).contains(bits), bits % 8 == 0 else { throw .damaged("an RC4 key of \(bits) bits") }
        let v = h + headerSize
        guard le32(b, v) == 16 else { throw .damaged("salt size \(le32(b, v))") }
        guard le32(b, v + 36) == 20 else { throw .damaged("verifier hash size \(le32(b, v + 36))") }
        keyBits = bits
        salt = Array(b[v + 4 ..< v + 20])
        verifier = Array(b[v + 20 ..< v + 36])
        verifierHash = Array(b[v + 40 ..< v + 60])
    }

    /// The password hash H0 = SHA-1(salt + password): what every block's key comes from.
    public struct Key: Sendable {
        let h0: [UInt8]
        let keyBits: Int

        /// RC4 for `block`, its state fresh.
        public func cipher(block: UInt32) -> RC4 {
            var k = Hash.sha1.digest(h0 + le32(block))
            k = Array(k.prefix(keyBits / 8))
            // A 40-bit key is padded with zeros to 128 bits ([MS-OFFCRYPTO] 2.3.5.2).
            if keyBits == 40 { k += [UInt8](repeating: 0, count: 11) }
            return RC4(key: k)
        }
    }

    /// The key for `password`, or nil when it isn't the file's password ([MS-OFFCRYPTO] 2.3.5.6: the verifier and
    /// its hash are decrypted in one RC4 stream with block 0's key).
    public func key(password: String) -> Key? {
        let pw = Array(password.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let key = Key(h0: Hash.sha1.digest(salt + pw), keyBits: keyBits)
        let rc4 = key.cipher(block: 0)
        let v = rc4.process(verifier)
        let hash = rc4.process(verifierHash)
        return Hash.sha1.digest(v) == hash ? key : nil
    }
}

/// An RC4 stream: each call continues where the last one ended.
public final class RC4: @unchecked Sendable {
    private var cryptor: CCCryptorRef?

    init(key: [UInt8]) {
        var ref: CCCryptorRef?
        let status = CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmRC4), 0, key, key.count, nil, &ref)
        cryptor = status == kCCSuccess ? ref : nil
    }

    deinit { if let cryptor { CCCryptorRelease(cryptor) } }

    /// The next `data.count` bytes of the stream XORed with `data` (RC4 decrypts and encrypts alike).
    @discardableResult
    public func process(_ data: [UInt8]) -> [UInt8] {
        guard let cryptor, !data.isEmpty else { return data }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCryptorUpdate(cryptor, data, data.count, &out, out.count, &moved)
        return status == kCCSuccess && moved == data.count ? out : data
    }

    public func process(_ data: ArraySlice<UInt8>) -> [UInt8] { process(Array(data)) }
}
