// CNZip — errors from ZIP and DEFLATE. Malformed archives never trap: they fail with one of these.
// Copied with Zip.swift and Deflate.swift from PhotoCraftNative (Packages/PCIO/Sources/PCIOCore at
// 7fa4dcc, where they were `PCIOError` cases).

public enum ZipError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Structurally invalid data.
    case corrupt(String)
    /// A feature of the archive is not supported (encryption, multi-disk archives…).
    case unsupported(String)
    /// A size or count exceeded a safety limit.
    case limitExceeded(String)
    /// DEFLATE failed.
    case codec(String)
    /// File-system failure.
    case io(String)

    public var description: String {
        switch self {
        case let .corrupt(m): "corrupt: \(m)"
        case let .unsupported(m): "unsupported: \(m)"
        case let .limitExceeded(m): "limit exceeded: \(m)"
        case let .codec(m): "codec: \(m)"
        case let .io(m): "I/O: \(m)"
        }
    }
}
