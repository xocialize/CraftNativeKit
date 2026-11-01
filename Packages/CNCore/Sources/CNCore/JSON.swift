// CNCore — the JSON value the port reads and writes in place of serde_json's `Value`.
//
// deckcraft keeps its documents as serde-derived JSON (`.deckcraft`, command parameters and answers,
// MCP). Swift's JSONEncoder can't reproduce serde_json's output (field order rules, `960.0` vs `960`,
// null for absent options), so the port carries its own value type, writer and parser, written to
// behave as serde_json 1.0.154 does (MIT OR Apache-2.0).

/// A JSON value. Numbers keep serde_json's distinction between integers and floats: a float is
/// written with a decimal point or exponent (`960.0`), an integer without.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// A non-negative integer (serde_json's `u64`).
    case uint(UInt64)
    /// A negative integer (serde_json's `i64`). The parser only makes it for negative numbers; the
    /// writer prints any value.
    case int(Int64)
    case double(Double)
    /// A value Rust serialised as `f32`: written with `f32`'s shortest digits. The parser never
    /// produces it.
    case float(Float)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    public static func integer<T: BinaryInteger>(_ v: T) -> JSON {
        if v < 0 { return .int(Int64(clamping: v)) }
        return .uint(UInt64(clamping: v))
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The object's value for `key`, or nil when this isn't an object or has no such key.
    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// serde_json's name for the value's type, as its "invalid type" errors use it.
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool(let b): "boolean `\(b)`"
        case .uint(let v): "integer `\(v)`"
        case .int(let v): "integer `\(v)`"
        case .double(let v): "floating point `\(v)`"
        case .float(let v): "floating point `\(v)`"
        case .string(let s): "string \"\(s)\""
        case .array: "sequence"
        case .object: "map"
        }
    }
}

/// A JSON object that keeps its keys in insertion order, as serde writes struct fields.
public struct JSONObject: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var key: String
        public var value: JSON
        public init(key: String, value: JSON) {
            self.key = key
            self.value = value
        }
    }

    public private(set) var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    public init(_ pairs: KeyValuePairs<String, JSON>) {
        entries = pairs.map { Entry(key: $0.key, value: $0.value) }
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    public var keys: [String] { entries.map(\.key) }

    /// The first value under `key`.
    public subscript(key: String) -> JSON? {
        entries.first { $0.key == key }?.value
    }

    /// Appends a key; a later duplicate is kept, as a map serialiser would write it.
    public mutating func append(_ key: String, _ value: JSON) {
        entries.append(Entry(key: key, value: value))
    }

    /// Replaces the first value under `key`, or appends it.
    public mutating func set(_ key: String, _ value: JSON) {
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries[i].value = value
        } else {
            append(key, value)
        }
    }

    public mutating func remove(_ key: String) {
        entries.removeAll { $0.key == key }
    }
}
