// CNOffCrypto — a presentation's password to modify: the `<p:modifyVerifier>` element of `ppt/presentation.xml`
// (ECMA-376 Part 1, PresentationML). It isn't encryption: the file stays readable, and PowerPoint asks for the
// password before letting the file be saved over, offering Read Only instead. The verifier is a salted, iterated
// hash: H0 = H(salt + password as UTF-16LE), then H(previous + counter) for each round, the 32-bit little-endian
// counter appended (the reverse of [MS-OFFCRYPTO]'s order for the password to open). The order was confirmed
// against PowerPoint 16's own files (Docs/plans/Legacy-PPT-and-Encryption.md, E3 notes). PowerPoint writes SHA-512
// (`cryptAlgorithmSid="14"`) with 100,000 rounds; SHA-1, SHA-256 and SHA-384 (4, 12, 13) are read too.
import Foundation

public struct ModifyVerifier: Sendable, Equatable {
    let hash: Hash
    public let spinCount: Int
    let salt: [UInt8]
    let value: [UInt8]

    static let sids: [Int: Hash] = [4: .sha1, 12: .sha256, 13: .sha384, 14: .sha512]

    /// The verifier in a `presentation.xml`, nil when it has none (or one this can't read).
    public static func find(inPresentationXML xml: String) -> ModifyVerifier? {
        guard let start = xml.range(of: "<p:modifyVerifier"), let end = xml[start.upperBound...].range(of: ">") else { return nil }
        let tag = String(xml[start.upperBound ..< end.lowerBound])
        var attrs: [String: String] = [:]
        let scanner = Scanner(string: tag)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        while !scanner.isAtEnd {
            guard let key = scanner.scanUpToString("="), scanner.scanString("=\"") != nil else { break }
            let value = scanner.scanUpToString("\"") ?? ""
            _ = scanner.scanString("\"")
            attrs[key.trimmingCharacters(in: .whitespaces)] = value
        }
        // The current attribute names, and the older ones (algorithmName / hashValue / saltValue are ECMA's newer
        // form; cryptAlgorithmSid / hashData / saltData what PowerPoint writes).
        let hash: Hash?
        if let sid = attrs["cryptAlgorithmSid"].flatMap({ Int($0) }) { hash = sids[sid] } else { hash = attrs["algorithmName"].flatMap(Hash.init) }
        guard let hash,
              let spin = attrs["spinCount"].flatMap({ Int($0) }), (0 ... 10_000_000).contains(spin),
              let salt = (attrs["saltData"] ?? attrs["saltValue"]).flatMap({ Data(base64Encoded: $0) }),
              let value = (attrs["hashData"] ?? attrs["hashValue"]).flatMap({ Data(base64Encoded: $0) }),
              value.count == hash.size
        else { return nil }
        return ModifyVerifier(hash: hash, spinCount: spin, salt: [UInt8](salt), value: [UInt8](value))
    }

    /// A new verifier for `password`, as PowerPoint 16 writes one.
    public static func make(password: String, random: (Int) -> [UInt8] = OfficeCrypto.secureRandom) -> ModifyVerifier {
        let salt = random(16)
        return ModifyVerifier(hash: .sha512, spinCount: 100_000, salt: salt, value: digest(.sha512, salt, password, 100_000))
    }

    /// Whether `password` is the password to modify.
    public func matches(_ password: String) -> Bool {
        Self.digest(hash, salt, password, spinCount) == value
    }

    static func digest(_ h: Hash, _ salt: [UInt8], _ password: String, _ spin: Int) -> [UInt8] {
        let pw = Array(password.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        var v = h.digest(salt + pw)
        var buf = [UInt8](repeating: 0, count: v.count + 4)
        for i in 0 ..< spin {
            buf.replaceSubrange(0 ..< v.count, with: v)
            buf[v.count] = UInt8(truncatingIfNeeded: i)
            buf[v.count + 1] = UInt8(truncatingIfNeeded: i >> 8)
            buf[v.count + 2] = UInt8(truncatingIfNeeded: i >> 16)
            buf[v.count + 3] = UInt8(truncatingIfNeeded: i >> 24)
            v = h.digest(buf)
        }
        return v
    }

    /// The element, as PowerPoint writes it.
    public var element: String {
        let sid = Self.sids.first { $0.value == hash }?.key ?? 14
        return #"<p:modifyVerifier cryptProviderType="rsaAES" cryptAlgorithmClass="hash" cryptAlgorithmType="typeAny" cryptAlgorithmSid="\#(sid)" spinCount="\#(spinCount)" saltData="\#(Base64.encode(salt))" hashData="\#(Base64.encode(value))"/>"#
    }

    /// `xml` with this verifier in place of any it had, where the schema puts it: after `defaultTextStyle`, before
    /// `extLst`, at the end of `p:presentation`.
    public func insert(intoPresentationXML xml: String) -> String {
        let clean = Self.remove(fromPresentationXML: xml)
        if let ext = clean.range(of: "<p:extLst") ?? clean.range(of: "</p:presentation>") {
            return clean.replacingCharacters(in: ext.lowerBound ..< ext.lowerBound, with: element)
        }
        return clean
    }

    /// `xml` without a verifier.
    public static func remove(fromPresentationXML xml: String) -> String {
        guard let start = xml.range(of: "<p:modifyVerifier"), let end = xml[start.upperBound...].range(of: ">") else { return xml }
        return xml.replacingCharacters(in: start.lowerBound ..< end.upperBound, with: "")
    }
}
