// CNZip — copied from PhotoCraftNative (xocialize/PhotoCraftNative, Packages/PCIO/Sources/PCIOCore/Deflate.swift at
// 7fa4dcc), which ports photocraft (MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors).
// Used by DeckCraftNative (DCFormat, DCPPTX) and Marquee Documents. Errors are `ZipError` here.
//
// DEFLATE, zlib and gzip through Apple's Compression framework, and the IEEE CRC-32.
// Replaces the flate2 and crc32fast crates photocraft-io and photocraft-format use (ZIP entries,
// Paint.NET's gzip chunks, `.svgz`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.
//
// `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951); the zlib (RFC 1950) and gzip (RFC 1952) wrappers
// are added here. Every decoder takes an output limit and never allocates from a declared size.

import Compression
import Foundation

public enum Deflate {
    /// Inflates a raw DEFLATE stream. Fails when the output would exceed `limit` bytes or the
    /// stream is malformed or truncated.
    public static func inflate(_ src: [UInt8], limit: Int = .max) throws -> [UInt8] {
        try process(src, operation: COMPRESSION_STREAM_DECODE, limit: limit)
    }

    /// Compresses into a raw DEFLATE stream.
    public static func deflate(_ src: [UInt8]) throws -> [UInt8] {
        try process(src, operation: COMPRESSION_STREAM_ENCODE, limit: .max)
    }

    /// Inflates a zlib stream (2-byte header, DEFLATE data, Adler-32). The checksum is verified
    /// when present.
    public static func zlibInflate(_ src: [UInt8], limit: Int = .max) throws -> [UInt8] {
        guard src.count >= 2, src[0] & 0x0F == 8, (UInt16(src[0]) << 8 | UInt16(src[1])) % 31 == 0 else {
            throw ZipError.corrupt("not a zlib stream")
        }
        if src[1] & 0x20 != 0 { throw ZipError.unsupported("zlib preset dictionary") }
        let out = try inflate(Array(src[2...]), limit: limit)
        if src.count >= 6 {
            let n = src.count
            let stored = UInt32(src[n - 4]) << 24 | UInt32(src[n - 3]) << 16 | UInt32(src[n - 2]) << 8 | UInt32(src[n - 1])
            if stored != adler32(out) { throw ZipError.corrupt("zlib checksum mismatch") }
        }
        return out
    }

    /// Compresses into a zlib stream.
    public static func zlibDeflate(_ src: [UInt8]) throws -> [UInt8] {
        let body = try deflate(src)
        let a = adler32(src)
        return [0x78, 0x9C] + body + [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)]
    }

    /// `true` for the gzip magic.
    public static func isGzip(_ src: [UInt8]) -> Bool { src.count >= 2 && src[0] == 0x1F && src[1] == 0x8B }

    /// Inflates a gzip member (header fields skipped, CRC-32 and size verified).
    public static func gunzip(_ src: [UInt8], limit: Int = .max) throws -> [UInt8] {
        guard src.count >= 18, isGzip(src), src[2] == 8 else { throw ZipError.corrupt("not a gzip stream") }
        let flags = src[3]
        var at = 10
        if flags & 4 != 0 {
            guard at + 2 <= src.count else { throw ZipError.corrupt("truncated gzip header") }
            at += 2 + Int(src[at]) | Int(src[at + 1]) << 8
        }
        if flags & 8 != 0 { while at < src.count, src[at] != 0 { at += 1 }; at += 1 }
        if flags & 16 != 0 { while at < src.count, src[at] != 0 { at += 1 }; at += 1 }
        if flags & 2 != 0 { at += 2 }
        guard at <= src.count - 8 else { throw ZipError.corrupt("truncated gzip stream") }
        let out = try inflate(Array(src[at ..< src.count - 8]), limit: limit)
        let n = src.count
        let crc = UInt32(src[n - 8]) | UInt32(src[n - 7]) << 8 | UInt32(src[n - 6]) << 16 | UInt32(src[n - 5]) << 24
        let size = UInt32(src[n - 4]) | UInt32(src[n - 3]) << 8 | UInt32(src[n - 2]) << 16 | UInt32(src[n - 1]) << 24
        if crc != CRC32.checksum(out) || size != UInt32(truncatingIfNeeded: out.count) {
            throw ZipError.corrupt("gzip checksum mismatch")
        }
        return out
    }

    /// Compresses into a gzip member.
    public static func gzip(_ src: [UInt8]) throws -> [UInt8] {
        let body = try deflate(src)
        let crc = CRC32.checksum(src)
        let size = UInt32(truncatingIfNeeded: src.count)
        var out: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]
        out += body
        for v in [crc, size] { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        return out
    }

    /// Adler-32 (zlib's checksum).
    public static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < data.count {
            let end = min(i + 5552, data.count)
            while i < end {
                a &+= UInt32(data[i])
                b &+= a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    private static func process(_ src: [UInt8], operation: compression_stream_operation, limit: Int) throws -> [UInt8] {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.codec("compression stream init failed")
        }
        defer { compression_stream_destroy(&stream) }
        let chunk = 1 << 16
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunk)
        let decode = operation == COMPRESSION_STREAM_DECODE
        return try src.withUnsafeBufferPointer { s -> [UInt8] in
            stream.src_ptr = s.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = s.count
            while true {
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { b in
                    stream.dst_ptr = b.baseAddress!
                    stream.dst_size = chunk
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    if out.count + produced > limit { throw ZipError.limitExceeded("decompressed data exceeds \(limit) bytes") }
                    out.append(contentsOf: buffer[0 ..< produced])
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return out
                case COMPRESSION_STATUS_OK:
                    // No progress on either side means the input ended inside the stream.
                    if produced == 0, stream.src_size == 0, decode {
                        throw ZipError.corrupt("truncated deflate stream")
                    }
                default:
                    throw ZipError.corrupt(decode ? "malformed deflate stream" : "deflate failed")
                }
            }
        }
    }
}

/// CRC-32 (IEEE 802.3, reflected, as stored in ZIP, gzip and PNG).
public enum CRC32 {
    static let table: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// The CRC of `data`.
    public static func checksum(_ data: [UInt8]) -> UInt32 { update(0, data) }

    /// Continues a CRC with more bytes (`update(update(0, a), b) == checksum(a + b)`).
    public static func update(_ crc: UInt32, _ data: [UInt8]) -> UInt32 {
        var c = ~crc
        data.withUnsafeBufferPointer { p in
            table.withUnsafeBufferPointer { t in
                for b in p { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return ~c
    }
}
