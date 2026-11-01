// CNCFB — writes a compound file ([MS-CFB] v20210625), version 3 (512-byte sectors, the default) or 4 (4096): what a password-protected
// `.pptx` is wrapped in (CNOffCrypto's writer, Docs/plans/Legacy-PPT-and-Encryption.md E3). Streams under 4096 bytes
// go to the mini stream; the rest get sectors of their own. The layout is fixed for given input: the mini stream,
// then the large streams in directory order, the directory, the mini FAT, the FAT and the DIFAT. Each storage's
// children form a balanced binary tree in the format's name order, every node black, which the specification
// allows ("the simplest implementation … mark every node as black", 2.6.4). Timestamps are left zero.

/// Builds a compound file from storages and streams named by slash-separated paths.
public struct CompoundFileWriter: Sendable {
    struct Node: Sendable {
        var name: String
        var kind: Entry.Kind
        var data: [UInt8] = []
        var clsid: [UInt8] = Array(repeating: 0, count: 16)
        var children: [Int] = []
    }

    var nodes: [Node] = [Node(name: "Root Entry", kind: .root)]
    /// 3 or 4.
    public let version: Int
    let sector: Int
    var perSector: Int { sector / 4 }

    /// A writer for version 3 (512-byte sectors; Apache POI and msoffcrypto-tool write protected files so) or 4
    /// (4096-byte sectors; PowerPoint 16 writes protected files so).
    public init(version: Int = 3) {
        self.version = version == 4 ? 4 : 3
        sector = version == 4 ? 4096 : 512
    }

    /// The root's class id (16 bytes; zeros by default).
    public mutating func setRootCLSID(_ clsid: [UInt8]) throws(CFBError) {
        guard clsid.count == 16 else { throw .invalid("a class id is 16 bytes") }
        nodes[0].clsid = clsid
    }

    /// Adds a storage (and any storage above it that isn't there yet).
    @discardableResult
    public mutating func addStorage(_ path: String, clsid: [UInt8]? = nil) throws(CFBError) -> Int {
        var at = 0
        for name in try Self.split(path) {
            if let i = nodes[at].children.first(where: { CFBName.equal(nodes[$0].name, name) }) {
                guard nodes[i].kind == .storage else { throw .invalid("\(path): \(name) is a stream") }
                at = i
            } else {
                nodes.append(Node(name: name, kind: .storage))
                nodes[at].children.append(nodes.count - 1)
                at = nodes.count - 1
            }
        }
        if let clsid {
            guard clsid.count == 16 else { throw .invalid("a class id is 16 bytes") }
            nodes[at].clsid = clsid
        }
        return at
    }

    /// Adds a stream, creating the storages above it.
    public mutating func addStream(_ path: String, _ data: [UInt8]) throws(CFBError) {
        var names = try Self.split(path)
        guard let leaf = names.popLast() else { throw .invalid("an empty path") }
        let parent = try addStorage(names.joined(separator: "/"))
        guard !nodes[parent].children.contains(where: { CFBName.equal(nodes[$0].name, leaf) }) else {
            throw .invalid("\(path) is already there")
        }
        nodes.append(Node(name: leaf, kind: .stream, data: data))
        nodes[parent].children.append(nodes.count - 1)
    }

    static func split(_ path: String) throws(CFBError) -> [String] {
        let names = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for n in names {
            guard n.utf16.count <= 31 else { throw .invalid("\(n) is longer than 31 characters") }
            guard !n.contains(where: { "\\:!".contains($0) }) else { throw .invalid("\(n) contains \\, : or !") }
        }
        return names
    }

    // MARK: Layout

    /// The file's bytes.
    public func bytes() throws(CFBError) -> [UInt8] {
        // Directory ids: the root, then each storage's children in name order, breadth first.
        var order: [Int] = [0]
        var head = 0
        while head < order.count {
            let n = nodes[order[head]]
            head += 1
            order += n.children.sorted { CFBName.compare(nodes[$0].name, nodes[$1].name) < 0 }
        }
        var dirID = [Int](repeating: 0, count: nodes.count)
        for (i, n) in order.enumerated() { dirID[n] = i }

        // The mini stream, and the mini FAT that chains it.
        let cutoff = CompoundFile.miniStreamCutoff, mini = CompoundFile.miniSectorSize
        var miniStream: [UInt8] = []
        var miniFAT: [UInt32] = []
        var miniStart = [Int: UInt32]()
        for n in order where nodes[n].kind == .stream && !nodes[n].data.isEmpty && nodes[n].data.count < cutoff {
            let first = miniFAT.count
            let count = (nodes[n].data.count + mini - 1) / mini
            miniStart[n] = UInt32(first)
            for k in 0 ..< count { miniFAT.append(k == count - 1 ? CompoundFile.endOfChain : UInt32(first + k + 1)) }
            miniStream += nodes[n].data
            miniStream += [UInt8](repeating: 0, count: count * mini - nodes[n].data.count)
        }

        // Sectors: the mini stream, the large streams, the directory, the mini FAT; then the FAT and the DIFAT.
        func sectors(_ byteCount: Int) -> Int { (byteCount + sector - 1) / sector }
        var runs: [(owner: Int, count: Int)] = []    // owner: node index, -1 mini stream, -2 directory, -3 mini FAT
        if !miniStream.isEmpty { runs.append((-1, sectors(miniStream.count))) }
        for n in order where nodes[n].kind == .stream && nodes[n].data.count >= cutoff {
            runs.append((n, sectors(nodes[n].data.count)))
        }
        runs.append((-2, sectors(order.count * CompoundFile.entrySize)))
        if !miniFAT.isEmpty { runs.append((-3, sectors(miniFAT.count * 4))) }
        let dataSectors = runs.reduce(0) { $0 + $1.count }
        var fatCount = 1, difatCount = 0
        while true {
            let total = dataSectors + fatCount + difatCount
            let f = (total + perSector - 1) / perSector
            let d = f > 109 ? (f - 109 + perSector - 2) / (perSector - 1) : 0
            if f == fatCount && d == difatCount { break }
            fatCount = f
            difatCount = d
        }
        guard dataSectors + fatCount + difatCount < Int(CompoundFile.maxRegSect) else { throw .invalid("too large") }

        var fat = [UInt32](repeating: CompoundFile.freeSect, count: fatCount * perSector)
        var start = [Int: UInt32]()
        var next = 0
        for run in runs {
            start[run.owner] = UInt32(next)
            for k in 0 ..< run.count { fat[next + k] = k == run.count - 1 ? CompoundFile.endOfChain : UInt32(next + k + 1) }
            next += run.count
        }
        let fatStart = next
        for k in 0 ..< fatCount { fat[fatStart + k] = CompoundFile.fatSect }
        let difatStart = fatStart + fatCount
        for k in 0 ..< difatCount { fat[difatStart + k] = CompoundFile.difSect }

        // The directory.
        var dir: [UInt8] = []
        dir.reserveCapacity(sectors(order.count * CompoundFile.entrySize) * sector)
        // Each storage's children as a balanced tree: (left, right) per node, and the storage's child.
        var left = [Int: UInt32](), right = [Int: UInt32](), child = [Int: UInt32]()
        func build(_ sorted: ArraySlice<Int>) -> UInt32 {
            guard !sorted.isEmpty else { return CompoundFile.noStream }
            let mid = sorted.startIndex + sorted.count / 2
            left[sorted[mid]] = build(sorted[sorted.startIndex ..< mid])
            right[sorted[mid]] = build(sorted[(mid + 1)...])
            return UInt32(dirID[sorted[mid]])
        }
        for n in order where nodes[n].kind != .stream {
            child[n] = build(ArraySlice(nodes[n].children.sorted { CFBName.compare(nodes[$0].name, nodes[$1].name) < 0 }))
        }
        for n in order {
            let node = nodes[n]
            let type: UInt8 = switch node.kind { case .root: 5; case .storage: 1; case .stream: 2 }
            let (first, size): (UInt32, Int) = switch node.kind {
            case .root: miniStream.isEmpty ? (CompoundFile.endOfChain, 0) : (start[-1] ?? 0, miniStream.count)
            case .storage: (0, 0)
            case .stream:
                node.data.isEmpty ? (CompoundFile.endOfChain, 0)
                    : (node.data.count < cutoff ? miniStart[n] ?? 0 : start[n] ?? 0, node.data.count)
            }
            dir += Self.entry(name: node.name, type: type, left: left[n] ?? CompoundFile.noStream,
                              right: right[n] ?? CompoundFile.noStream, child: child[n] ?? CompoundFile.noStream,
                              clsid: node.clsid, start: first, size: UInt64(size))
        }
        while dir.count % sector != 0 { dir += Self.emptyEntry }

        // The header.
        var out = CompoundFile.signature
        out += [UInt8](repeating: 0, count: 16)                         // header CLSID
        out += le16(0x003E) + le16(UInt16(version)) + le16(0xFFFE) + le16(version == 4 ? 12 : 9) + le16(6)
        out += [UInt8](repeating: 0, count: 6)
        out += le32(version == 4 ? UInt32(sectors(order.count * CompoundFile.entrySize)) : 0)   // 0 in version 3
        out += le32(UInt32(fatCount))
        out += le32(start[-2] ?? 0)
        out += le32(0)                                                  // transaction signature
        out += le32(UInt32(cutoff))
        out += le32(miniFAT.isEmpty ? CompoundFile.endOfChain : start[-3] ?? 0)
        out += le32(UInt32(sectors(miniFAT.count * 4)))
        out += le32(difatCount == 0 ? CompoundFile.endOfChain : UInt32(difatStart))
        out += le32(UInt32(difatCount))
        for k in 0 ..< 109 { out += le32(k < fatCount ? UInt32(fatStart + k) : CompoundFile.freeSect) }
        out += [UInt8](repeating: 0, count: sector - 512)               // version 4's header fills its sector

        // The sectors, in allocation order.
        func pad(_ b: [UInt8]) -> [UInt8] { b + [UInt8](repeating: 0, count: (sector - b.count % sector) % sector) }
        for run in runs {
            switch run.owner {
            case -1: out += pad(miniStream)
            case -2: out += dir
            case -3:
                var m = miniFAT
                while m.count % perSector != 0 { m.append(CompoundFile.freeSect) }
                for v in m { out += le32(v) }
            default: out += pad(nodes[run.owner].data)
            }
        }
        for v in fat { out += le32(v) }
        // The DIFAT: the FAT sector ids beyond the header's 109, a sector's worth less one per sector, each ending with
        // the next DIFAT sector's id.
        var rest = fatCount > 109 ? Array((fatStart + 109 ..< fatStart + fatCount).map(UInt32.init)) : []
        for k in 0 ..< difatCount {
            let take = min(rest.count, perSector - 1)
            var s = Array(rest[0 ..< take])
            rest.removeFirst(take)
            while s.count < perSector - 1 { s.append(CompoundFile.freeSect) }
            s.append(k == difatCount - 1 ? CompoundFile.endOfChain : UInt32(difatStart + k + 1))
            for v in s { out += le32(v) }
        }
        return out
    }

    static func entry(name: String, type: UInt8, left: UInt32, right: UInt32, child: UInt32, clsid: [UInt8],
                      start: UInt32, size: UInt64) -> [UInt8] {
        var e: [UInt8] = []
        e.reserveCapacity(CompoundFile.entrySize)
        let units = Array(name.utf16.prefix(31))
        for u in units { e += le16(u) }
        e += [UInt8](repeating: 0, count: 64 - units.count * 2)
        e += le16(UInt16((units.count + 1) * 2))
        e += [type, 1]                                                  // black
        e += le32(left) + le32(right) + le32(child)
        e += clsid
        e += le32(0)                                                    // state bits
        e += [UInt8](repeating: 0, count: 16)                           // creation and modified times
        e += le32(start)
        e += le32(UInt32(truncatingIfNeeded: size)) + le32(UInt32(truncatingIfNeeded: size >> 32))
        return e
    }

    /// An unused directory slot.
    static let emptyEntry: [UInt8] = {
        var e = [UInt8](repeating: 0, count: 66)
        e += [0, 0]
        e += le32(CompoundFile.noStream) + le32(CompoundFile.noStream) + le32(CompoundFile.noStream)
        e += [UInt8](repeating: 0, count: 16 + 4 + 16 + 4 + 8)
        return e
    }()
}

/// Directory names as the format orders them ([MS-CFB] 2.6.4): a shorter name sorts first; names of the same length
/// compare code unit by code unit after upper-casing each (a surrogate is never upper-cased).
public enum CFBName {
    public static func compare(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf16), y = Array(b.utf16)
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
        for (p, q) in zip(x, y) {
            let up = upper(p), uq = upper(q)
            if up != uq { return up < uq ? -1 : 1 }
        }
        return 0
    }

    public static func equal(_ a: String, _ b: String) -> Bool { compare(a, b) == 0 }

    static func upper(_ u: UInt16) -> UInt16 {
        guard !UTF16.isLeadSurrogate(u), !UTF16.isTrailSurrogate(u), let s = Unicode.Scalar(u) else { return u }
        let up = Array(String(Character(s)).uppercased().utf16)
        return up.count == 1 ? up[0] : u
    }
}

func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
