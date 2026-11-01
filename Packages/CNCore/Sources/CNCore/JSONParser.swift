// CNCore — a strict JSON parser that accepts what `serde_json::from_slice` accepts (serde_json
// 1.0.154, MIT OR Apache-2.0): no trailing commas, comments or leading zeros, at most 128 levels of
// nesting, lone surrogates refused. Integers become `.uint`/`.int` and everything else `.double`;
// an integer too large for 64 bits becomes a float, as in serde_json.

public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    /// 1-based, as serde_json reports them.
    public var line: Int
    public var column: Int

    public var description: String { "\(message) at line \(line) column \(column)" }
}

public enum JSONParser {
    /// serde_json's default recursion limit.
    public static let maxDepth = 128

    public static func parse(_ bytes: some Collection<UInt8>) throws(JSONParseError) -> JSON {
        var p = Parser(bytes: Array(bytes))
        p.skipWhitespace()
        let value = try p.value(depth: 0)
        p.skipWhitespace()
        if p.i < p.bytes.count { throw p.error("trailing characters") }
        return value
    }

    public static func parse(_ text: String) throws(JSONParseError) -> JSON {
        try parse(Array(text.utf8))
    }
}

private struct Parser {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func error(_ message: String) -> JSONParseError {
        // Line and column of the byte at `i` (or one past the end).
        var line = 1
        var column = 0
        for b in bytes[..<min(i + 1, bytes.count)] {
            if b == 0x0A {
                line += 1
                column = 0
            } else {
                column += 1
            }
        }
        return JSONParseError(message: message, line: line, column: column)
    }

    var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

    mutating func skipWhitespace() {
        while let b = peek, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1 }
    }

    mutating func value(depth: Int) throws(JSONParseError) -> JSON {
        guard let b = peek else { throw error("EOF while parsing a value") }
        switch b {
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"): return try number()
        case UInt8(ascii: "["):
            guard depth < JSONParser.maxDepth else { throw error("recursion limit exceeded") }
            return try array(depth: depth + 1)
        case UInt8(ascii: "{"):
            guard depth < JSONParser.maxDepth else { throw error("recursion limit exceeded") }
            return try object(depth: depth + 1)
        default:
            throw error("expected value")
        }
    }

    mutating func literal(_ word: String) throws(JSONParseError) {
        for c in word.utf8 {
            guard peek == c else { throw error(peek == nil ? "EOF while parsing a value" : "expected ident") }
            i += 1
        }
    }

    mutating func array(depth: Int) throws(JSONParseError) -> JSON {
        i += 1 // [
        var items: [JSON] = []
        skipWhitespace()
        if peek == UInt8(ascii: "]") {
            i += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try value(depth: depth))
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","):
                i += 1
                skipWhitespace()
                if peek == UInt8(ascii: "]") { throw error("trailing comma") }
            case UInt8(ascii: "]"):
                i += 1
                return .array(items)
            case nil:
                throw error("EOF while parsing a list")
            default:
                throw error("expected `,` or `]`")
            }
        }
    }

    mutating func object(depth: Int) throws(JSONParseError) -> JSON {
        i += 1 // {
        var o = JSONObject()
        skipWhitespace()
        if peek == UInt8(ascii: "}") {
            i += 1
            return .object(o)
        }
        while true {
            skipWhitespace()
            guard peek == UInt8(ascii: "\"") else {
                throw error(peek == nil ? "EOF while parsing an object" : "key must be a string")
            }
            let key = try string()
            skipWhitespace()
            guard peek == UInt8(ascii: ":") else { throw error(peek == nil ? "EOF while parsing an object" : "expected `:`") }
            i += 1
            skipWhitespace()
            o.append(key, try value(depth: depth))
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","):
                i += 1
                skipWhitespace()
                if peek == UInt8(ascii: "}") { throw error("trailing comma") }
            case UInt8(ascii: "}"):
                i += 1
                return .object(o)
            case nil:
                throw error("EOF while parsing an object")
            default:
                throw error("expected `,` or `}`")
            }
        }
    }

    mutating func string() throws(JSONParseError) -> String {
        i += 1 // opening quote
        var out: [UInt8] = []
        while true {
            guard let b = peek else { throw error("EOF while parsing a string") }
            i += 1
            switch b {
            case UInt8(ascii: "\""):
                guard let s = String(validating: out, as: UTF8.self) else {
                    throw error("invalid unicode code point")
                }
                return s
            case UInt8(ascii: "\\"):
                guard let e = peek else { throw error("EOF while parsing a string") }
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try unicodeEscape()
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw error("invalid escape")
                }
            case 0x00 ..< 0x20:
                throw error("control character (\\u0000-\\u001F) found while parsing a string")
            default:
                out.append(b)
            }
        }
    }

    mutating func hex4() throws(JSONParseError) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0 ..< 4 {
            guard let b = peek else { throw error("EOF while parsing a string") }
            let d: UInt32
            switch b {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): d = UInt32(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): d = UInt32(b - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): d = UInt32(b - UInt8(ascii: "A") + 10)
            default: throw error("invalid escape")
            }
            v = v * 16 + d
            i += 1
        }
        return v
    }

    mutating func unicodeEscape() throws(JSONParseError) -> Unicode.Scalar {
        let first = try hex4()
        switch first {
        case 0xD800 ... 0xDBFF:
            guard peek == UInt8(ascii: "\\"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "u") else {
                throw error("lone leading surrogate in hex escape")
            }
            i += 2
            let second = try hex4()
            guard (0xDC00 ... 0xDFFF).contains(second) else { throw error("lone leading surrogate in hex escape") }
            let v = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let s = Unicode.Scalar(v) else { throw error("invalid unicode code point") }
            return s
        case 0xDC00 ... 0xDFFF:
            throw error("lone leading surrogate in hex escape")
        default:
            guard let s = Unicode.Scalar(first) else { throw error("invalid unicode code point") }
            return s
        }
    }

    mutating func number() throws(JSONParseError) -> JSON {
        let start = i
        let negative = peek == UInt8(ascii: "-")
        if negative { i += 1 }
        guard let first = peek, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(first) else {
            throw error("invalid number")
        }
        i += 1
        if first == UInt8(ascii: "0") {
            if let b = peek, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(b) { throw error("invalid number") }
        } else {
            digits()
        }
        var isFloat = false
        if peek == UInt8(ascii: ".") {
            isFloat = true
            i += 1
            guard let b = peek, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(b) else { throw error("invalid number") }
            digits()
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            isFloat = true
            i += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
            guard let b = peek, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(b) else { throw error("invalid number") }
            digits()
        }
        let text = String(decoding: bytes[start ..< i], as: UTF8.self)
        if !isFloat {
            if negative, let v = Int64(text) { return .int(v) }
            if !negative, let v = UInt64(text) { return .uint(v) }
        }
        guard let d = Double(text) else { throw error("invalid number") }
        guard d.isFinite else { throw error("number out of range") }
        return .double(d)
    }

    mutating func digits() {
        while let b = peek, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(b) { i += 1 }
    }
}
