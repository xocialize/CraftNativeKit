// CNOffCrypto — the primitives [MS-OFFCRYPTO] needs, from CommonCrypto: SHA-1 and SHA-2 hashes, their HMACs, and
// AES in CBC and ECB modes without padding (the formats pad their own data).
import CommonCrypto

/// A hash named the way Agile encryption names it.
enum Hash: Sendable, Equatable {
    case sha1, sha256, sha384, sha512

    init?(_ name: String) {
        switch name.uppercased() {
        case "SHA1", "SHA-1": self = .sha1
        case "SHA256", "SHA-256": self = .sha256
        case "SHA384", "SHA-384": self = .sha384
        case "SHA512", "SHA-512": self = .sha512
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .sha1: "SHA1"
        case .sha256: "SHA256"
        case .sha384: "SHA384"
        case .sha512: "SHA512"
        }
    }

    var size: Int {
        switch self {
        case .sha1: Int(CC_SHA1_DIGEST_LENGTH)
        case .sha256: Int(CC_SHA256_DIGEST_LENGTH)
        case .sha384: Int(CC_SHA384_DIGEST_LENGTH)
        case .sha512: Int(CC_SHA512_DIGEST_LENGTH)
        }
    }

    func digest(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        let n = CC_LONG(data.count)
        data.withUnsafeBufferPointer { d in
            out.withUnsafeMutableBufferPointer { o in
                switch self {
                case .sha1: _ = CC_SHA1(d.baseAddress, n, o.baseAddress)
                case .sha256: _ = CC_SHA256(d.baseAddress, n, o.baseAddress)
                case .sha384: _ = CC_SHA384(d.baseAddress, n, o.baseAddress)
                case .sha512: _ = CC_SHA512(d.baseAddress, n, o.baseAddress)
                }
            }
        }
        return out
    }

    func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        let alg: CCHmacAlgorithm = switch self {
        case .sha1: CCHmacAlgorithm(kCCHmacAlgSHA1)
        case .sha256: CCHmacAlgorithm(kCCHmacAlgSHA256)
        case .sha384: CCHmacAlgorithm(kCCHmacAlgSHA384)
        case .sha512: CCHmacAlgorithm(kCCHmacAlgSHA512)
        }
        var out = [UInt8](repeating: 0, count: size)
        CCHmac(alg, key, key.count, data, data.count, &out)
        return out
    }
}

enum AES {
    /// Decrypts in CBC mode; the data must be whole 16-byte blocks.
    static func cbc(_ key: [UInt8], _ iv: [UInt8], _ data: [UInt8]) throws(OfficeCryptoError) -> [UInt8] {
        try run(key, iv, data, CCOptions(0))
    }

    /// Decrypts in ECB mode; the data must be whole 16-byte blocks.
    static func ecb(_ key: [UInt8], _ data: [UInt8]) throws(OfficeCryptoError) -> [UInt8] {
        try run(key, nil, data, CCOptions(kCCOptionECBMode))
    }

    /// Encrypts in CBC mode; the data must be whole 16-byte blocks.
    static func encryptCBC(_ key: [UInt8], _ iv: [UInt8], _ data: [UInt8]) throws(OfficeCryptoError) -> [UInt8] {
        try run(key, iv, data, CCOptions(0), op: CCOperation(kCCEncrypt))
    }

    static func run(_ key: [UInt8], _ iv: [UInt8]?, _ data: [UInt8], _ options: CCOptions,
                    op: CCOperation = CCOperation(kCCDecrypt)) throws(OfficeCryptoError) -> [UInt8] {
        guard [16, 24, 32].contains(key.count) else { throw .damaged("an AES key of \(key.count) bytes") }
        guard data.count % 16 == 0 else { throw .damaged("encrypted data that isn't whole AES blocks") }
        if let iv, iv.count != 16 { throw .damaged("an AES IV of \(iv.count) bytes") }
        if data.isEmpty { return [] }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options, key, key.count, iv, data, data.count,
                             &out, out.count, &moved)
        guard status == kCCSuccess, moved == data.count else { throw .damaged("AES failed (\(status))") }
        return out
    }
}
