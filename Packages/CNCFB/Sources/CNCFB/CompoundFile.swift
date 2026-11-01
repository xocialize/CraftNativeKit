// CNCFB — the Compound File Binary format ([MS-CFB] v20210625), read in full: version 3 (512-byte sectors) and
// version 4 (4096-byte sectors), the DIFAT beyond the header's 109 entries, the FAT, the mini FAT and mini stream,
// and the directory's red-black trees (walked through their child and sibling links; colours are ignored). It is
// the container of password-protected OOXML ([MS-OFFCRYPTO]: `EncryptionInfo`, `EncryptedPackage`) and of legacy
// `.ppt` ([MS-PPT]: `Current User`, `PowerPoint Document`, `Pictures`), and of the OLE objects inside them.
// Written from the specification (Docs/plans/Legacy-PPT-and-Encryption.md §1): not a port, deckcraft has no full
// reader. DCPPTX's `CFB` (deckcraft's encryption sniffer) stays as deckcraft wrote it, for its parity vectors.
//
// Every number in the file is hostile: sector ids are range-checked, every chain is followed at most once per
// sector (a cycle is an error, not a hang), a stream's size can't exceed the bytes its chain can hold, and the
// directory tree is walked iteratively with each entry visited once. Nothing here traps.

/// A compound file read from bytes.
public struct CompoundFile: Sendable {
    public static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    /// Sector ids at or above this are markers, not sectors.
    static let maxRegSect: UInt32 = 0xFFFF_FFFA
    static let difSect: UInt32 = 0xFFFF_FFFC
    static let fatSect: UInt32 = 0xFFFF_FFFD
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let freeSect: UInt32 = 0xFFFF_FFFF
    /// The "no entry" directory id.
    static let noStream: UInt32 = 0xFFFF_FFFF
    static let miniSectorSize = 64
    static let miniStreamCutoff = 4096
    static let entrySize = 128

    /// 3 (512-byte sectors) or 4 (4096-byte sectors).
    public let majorVersion: Int
    public let sectorSize: Int
    /// The root storage, whose children are the file's top-level storages and streams.
    public var root: Entry { entries[0] }
    /// Every entry reachable from the root, the root first, then depth first in the trees' order.
    public let entries: [Entry]

    let bytes: [UInt8]
    /// The sectors after the header.
    let sectorCount: Int
    let fat: [UInt32]
    let miniFAT: [UInt32]
    /// The mini stream (the root entry's stream), read once.
    let miniStream: [UInt8]

    /// Whether `bytes` starts with the compound-file signature.
    public static func isCompoundFile(_ bytes: [UInt8]) -> Bool { bytes.starts(with: signature) }

    public init(_ bytes: [UInt8]) throws(CFBError) {
        guard bytes.count >= 512, bytes.starts(with: Self.signature) else { throw .notCompoundFile }
        let h = bytes[0 ..< 512]
        guard u16(h, 28) == 0xFFFE else { throw .malformed("byte order mark") }
        let major = Int(u16(h, 26))
        let shift = Int(u16(h, 30))
        guard (major == 3 && shift == 9) || (major == 4 && shift == 12) else {
            throw .unsupported("version \(major) with sector shift \(shift)")
        }
        guard u16(h, 32) == 6 else { throw .malformed("mini sector shift \(u16(h, 32))") }
        let size = 1 << shift
        // Whole sectors after the header; a last sector cut short by the writer still counts (its bytes read as 0).
        let sectorCount = max(0, (bytes.count - size + size - 1) / size)
        self.bytes = bytes
        self.sectorCount = sectorCount
        majorVersion = major
        sectorSize = size

        let reader = Sectors(bytes: bytes, size: size, count: sectorCount)

        // The DIFAT: up to 109 FAT sector ids in the header, then chained DIFAT sectors (each ending with the next).
        var fatSectors: [UInt32] = []
        for i in 0 ..< 109 {
            let id = u32(h, 76 + i * 4)
            if id < Self.maxRegSect { fatSectors.append(id) }
        }
        let perSector = size / 4
        var difatID = u32(h, 68)
        var seen = Set<UInt32>()
        while difatID < Self.maxRegSect {
            guard seen.insert(difatID).inserted else { throw .malformed("the DIFAT chain loops") }
            guard let s = reader.sector(difatID) else { throw .malformed("DIFAT sector \(difatID) is outside the file") }
            for i in 0 ..< perSector - 1 {
                let id = u32(s, i * 4)
                if id < Self.maxRegSect { fatSectors.append(id) }
            }
            difatID = u32(s, (perSector - 1) * 4)
        }
        guard fatSectors.count <= sectorCount else { throw .malformed("more FAT sectors than the file holds") }

        // The FAT: one sector id per sector, for every sector the file has.
        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors.count * perSector)
        for id in fatSectors {
            guard let s = reader.sector(id) else { throw .malformed("FAT sector \(id) is outside the file") }
            for i in 0 ..< perSector { fat.append(u32(s, i * 4)) }
        }
        self.fat = fat
        let chains = Chains(fat: fat, sectors: reader)

        // The directory.
        let dirBytes = try chains.read(from: u32(h, 48), limit: nil, what: "the directory")
        let raw = stride(from: 0, to: dirBytes.count - Self.entrySize + 1, by: Self.entrySize).map {
            RawEntry(dirBytes[$0 ..< $0 + Self.entrySize], major: major)
        }
        guard let rootRaw = raw.first, rootRaw.type == 5 else { throw .malformed("the first directory entry isn't the root") }

        // The mini FAT and the mini stream.
        let miniFATBytes = try chains.read(from: u32(h, 60), limit: nil, what: "the mini FAT")
        miniFAT = stride(from: 0, to: miniFATBytes.count - 3, by: 4).map { u32(miniFATBytes[$0 ..< $0 + 4], 0) }
        miniStream = try chains.read(from: rootRaw.start, limit: rootRaw.size, what: "the mini stream")

        entries = try Self.walk(raw)
    }

    /// The entry at `path` (names compared case-insensitively, as the format does), or nil.
    public func entry(_ path: [String]) -> Entry? {
        entries.first { $0.path.count == path.count && zip($0.path, path).allSatisfy { CFBName.equal($0, $1) } }
    }

    /// The entry at a slash-separated path, such as "EncryptionInfo" or "\u{6}DataSpaces/Version".
    public func entry(_ path: String) -> Entry? {
        entry(path.split(separator: "/", omittingEmptySubsequences: true).map(String.init))
    }

    /// The direct children of a storage (or of the root), in the tree's order.
    public func children(of storage: Entry) -> [Entry] {
        entries.filter { $0.parent == storage.id }
    }

    /// Whether a stream or storage exists at the slash-separated `path`.
    public func contains(_ path: String) -> Bool { entry(path) != nil }

    /// The bytes of the stream at `path`.
    public func stream(_ path: String) throws(CFBError) -> [UInt8] {
        guard let e = entry(path) else { throw .notFound(path) }
        return try read(e)
    }

    /// The bytes of a stream entry.
    public func read(_ e: Entry) throws(CFBError) -> [UInt8] {
        guard e.kind == .stream else { throw .notFound(e.path.joined(separator: "/") + " (not a stream)") }
        if e.size == 0 { return [] }
        if e.size < UInt64(Self.miniStreamCutoff) {
            return try MiniChains(miniFAT: miniFAT, stream: miniStream).read(from: e.start, size: Int(e.size), what: e.name)
        }
        let reader = Sectors(bytes: bytes, size: sectorSize, count: sectorCount)
        return try Chains(fat: fat, sectors: reader).read(from: e.start, limit: e.size, what: e.name)
    }

    /// Every entry reachable from the root, each visited once; a link to an entry already seen, or out of range, is
    /// an error.
    static func walk(_ raw: [RawEntry]) throws(CFBError) -> [Entry] {
        var out: [Entry] = [Entry(id: 0, parent: -1, name: "Root Entry", path: [], kind: .root, size: raw[0].size,
                                  start: raw[0].start, clsid: raw[0].clsid)]
        var visited = Set<Int>([0])
        // Storages whose trees are still to walk: (directory id of the tree's root, parent entry, parent path).
        var storages: [(tree: UInt32, parent: Int, path: [String])] = [(raw[0].child, 0, [])]
        var head = 0
        while head < storages.count {
            let (tree, parent, path) = storages[head]
            head += 1
            // An in-order walk of one storage's tree (left, node, right), iterative.
            var stack: [UInt32] = []
            var node = tree
            var children: [Entry] = []
            while node != noStream || !stack.isEmpty {
                while node != noStream {
                    let i = Int(node)
                    guard i < raw.count else { throw .malformed("directory link \(node) is outside the directory") }
                    guard visited.insert(i).inserted else { throw .malformed("directory entry \(i) is linked twice") }
                    stack.append(node)
                    node = raw[i].left
                }
                guard let top = stack.popLast() else { break }
                let r = raw[Int(top)]
                let kind: Entry.Kind
                switch r.type {
                case 1: kind = .storage
                case 2: kind = .stream
                default: throw .malformed("directory entry \(top) has type \(r.type)")
                }
                children.append(Entry(id: Int(top), parent: parent, name: r.name, path: path + [r.name], kind: kind,
                                      size: kind == .stream ? r.size : 0, start: r.start, clsid: r.clsid))
                node = r.right
            }
            for c in children {
                out.append(c)
                if c.kind == .storage { storages.append((raw[c.id].child, c.id, c.path)) }
            }
        }
        return out
    }
}

/// One directory entry: a storage or a stream.
public struct Entry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case root, storage, stream }
    /// Its index in the directory.
    public let id: Int
    /// The directory index of its storage (the root's is -1).
    public let parent: Int
    public let name: String
    /// The names from the root down to this entry (empty for the root).
    public let path: [String]
    public let kind: Kind
    /// A stream's size in bytes (0 for storages; the mini stream's size for the root).
    public let size: UInt64
    let start: UInt32
    /// The class id, 16 bytes.
    public let clsid: [UInt8]
}

public enum CFBError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The bytes don't start with the compound-file signature (or are shorter than its header).
    case notCompoundFile
    /// A version or sector size this reader doesn't handle.
    case unsupported(String)
    /// Structurally invalid: out-of-range ids, cycles, short chains.
    case malformed(String)
    /// No stream or storage at a path.
    case notFound(String)
    /// The writer was given something it can't lay out.
    case invalid(String)

    public var description: String {
        switch self {
        case .notCompoundFile: "not a compound file"
        case let .unsupported(m): "unsupported compound file: \(m)"
        case let .malformed(m): "damaged compound file: \(m)"
        case let .notFound(p): "no \(p) in the compound file"
        case let .invalid(m): "can't write the compound file: \(m)"
        }
    }
}

// MARK: - Internals

/// A directory entry as stored.
struct RawEntry {
    let name: String
    let type: UInt8
    let left: UInt32, right: UInt32, child: UInt32
    let clsid: [UInt8]
    let start: UInt32
    let size: UInt64

    init(_ b: ArraySlice<UInt8>, major: Int) {
        let len = Int(u16(b, 64))
        // The length counts the terminating null, in bytes; anything outside 2…64 or odd gives an empty name.
        let units = (2 ... 64).contains(len) && len % 2 == 0 ? (len - 2) / 2 : 0
        name = String(decoding: (0 ..< units).map { u16(b, $0 * 2) }, as: UTF16.self)
        type = b[b.startIndex + 66]
        left = u32(b, 68)
        right = u32(b, 72)
        child = u32(b, 76)
        clsid = Array(b[b.startIndex + 80 ..< b.startIndex + 96])
        start = u32(b, 116)
        // Version 3 writers may leave junk in the high 32 bits ([MS-CFB] 2.6.3): ignore them there.
        let low = UInt64(u32(b, 120)), high = UInt64(u32(b, 124))
        size = major == 3 ? low : low | high << 32
    }
}

/// The file's sectors, by id.
struct Sectors {
    let bytes: [UInt8]
    let size: Int
    let count: Int

    /// Sector `id`'s bytes; a last sector cut short by the writer is padded with zeros. Nil when it isn't in the file.
    func sector(_ id: UInt32) -> ArraySlice<UInt8>? {
        guard id < CompoundFile.maxRegSect, Int(id) < count else { return nil }
        let start = (Int(id) + 1) * size
        guard start < bytes.count else { return nil }
        let end = start + size
        if end <= bytes.count { return bytes[start ..< end] }
        return ArraySlice(Array(bytes[start...]) + [UInt8](repeating: 0, count: end - bytes.count))
    }
}

/// Chains of sectors through the FAT.
struct Chains {
    let fat: [UInt32]
    let sectors: Sectors

    /// The chain from `start`, cut to `limit` bytes when given (a stream), or whole (the directory, the mini FAT).
    func read(from start: UInt32, limit: UInt64?, what: String) throws(CFBError) -> [UInt8] {
        if start == CompoundFile.endOfChain || start == CompoundFile.freeSect {
            if let limit, limit > 0 { throw .malformed("\(what) has a size but no sectors") }
            return []
        }
        // A stream can't hold more than the file's sectors.
        if let limit, limit > UInt64(sectors.count) * UInt64(sectors.size) {
            throw .malformed("\(what) claims \(limit) bytes, more than the file holds")
        }
        var out: [UInt8] = []
        if let limit { out.reserveCapacity(Int(limit)) }
        var id = start
        var seen = Set<UInt32>()
        while id != CompoundFile.endOfChain {
            if let limit, UInt64(out.count) >= limit { break }
            guard seen.insert(id).inserted else { throw .malformed("\(what)'s sector chain loops") }
            guard let s = sectors.sector(id), Int(id) < fat.count else {
                throw .malformed("\(what) runs to sector \(id), outside the file")
            }
            out += s
            id = fat[Int(id)]
        }
        if let limit {
            guard UInt64(out.count) >= limit else { throw .malformed("\(what) is shorter than its size") }
            out.removeLast(out.count - Int(limit))
        }
        return out
    }
}

/// Chains of 64-byte mini sectors through the mini FAT, inside the mini stream.
struct MiniChains {
    let miniFAT: [UInt32]
    let stream: [UInt8]

    func read(from start: UInt32, size: Int, what: String) throws(CFBError) -> [UInt8] {
        let unit = CompoundFile.miniSectorSize
        var out: [UInt8] = []
        out.reserveCapacity(size)
        var id = start
        var seen = Set<UInt32>()
        while out.count < size {
            guard id != CompoundFile.endOfChain else { throw .malformed("\(what) is shorter than its size") }
            guard seen.insert(id).inserted else { throw .malformed("\(what)'s mini sector chain loops") }
            let at = Int(id) * unit
            guard Int(id) < miniFAT.count, id < CompoundFile.maxRegSect, at + unit <= stream.count else {
                throw .malformed("\(what) runs to mini sector \(id), outside the mini stream")
            }
            out += stream[at ..< at + unit]
            id = miniFAT[Int(id)]
        }
        out.removeLast(out.count - size)
        return out
    }
}

/// Little-endian reads at an offset from a slice's start. Callers stay in bounds: a short read gives 0s, never a trap.
func u16(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt16 {
    let s = b.startIndex + at
    guard at >= 0, s + 2 <= b.endIndex else { return 0 }
    return UInt16(b[s]) | UInt16(b[s + 1]) << 8
}

func u32(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt32 {
    let s = b.startIndex + at
    guard at >= 0, s + 4 <= b.endIndex else { return 0 }
    return UInt32(b[s]) | UInt32(b[s + 1]) << 8 | UInt32(b[s + 2]) << 16 | UInt32(b[s + 3]) << 24
}
