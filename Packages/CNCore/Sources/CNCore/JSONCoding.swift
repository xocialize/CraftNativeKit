// CNCore — encoding and decoding model types to `JSON` the way serde's derive does:
//
// - a struct is an object whose keys follow the field order; an `Option` field that isn't skipped is
//   written as `null`;
// - on reading, unknown keys are ignored, a missing `Option` is nil, a missing field with a default
//   takes it, and any other missing field is an error;
// - integers refuse floats and out-of-range values; floats accept integers.
//
// Types conform by hand, mirroring each `#[serde(...)]` attribute of the Rust type they port.

public struct JSONDecodeError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public static func invalidType(_ found: JSON, expected: String) -> JSONDecodeError {
        JSONDecodeError("invalid type: \(found.typeName), expected \(expected)")
    }

    public static func missingField(_ key: String) -> JSONDecodeError {
        JSONDecodeError("missing field `\(key)`")
    }

    public static func unknownVariant(_ name: String, expected: [String]) -> JSONDecodeError {
        let list = expected.map { "`\($0)`" }.joined(separator: ", ")
        return JSONDecodeError("unknown variant `\(name)`, expected one of \(list)")
    }

    public var description: String { message }
}

public protocol JSONEncodable {
    func toJSON() -> JSON
}

public protocol JSONDecodable {
    init(fromJSON json: JSON) throws(JSONDecodeError)
}

public typealias JSONCodable = JSONDecodable & JSONEncodable

/// Decoding modes that change how values read, for the duration of a `withValue` scope.
public enum JSONDecoding {
    /// Read `null` where a float is required as 0. deckcraft-format's manifest parser patches each such
    /// `null` to `0` (serde_json writes NaN and ±infinity as `null`, so older files hold them); an
    /// `Option` float still reads `null` as nil.
    @TaskLocal public static var nullFloatsAsZero = false
}

/// Types serde fills in when their key is absent even without `#[serde(default)]`: `Option`.
public protocol JSONMissingValue {
    static var whenMissing: Self { get }
}

// MARK: - Scalars

extension Bool: JSONCodable {
    public func toJSON() -> JSON { .bool(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        guard case .bool(let b) = json else { throw .invalidType(json, expected: "a boolean") }
        self = b
    }
}

extension String: JSONCodable {
    public func toJSON() -> JSON { .string(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        guard case .string(let s) = json else { throw .invalidType(json, expected: "a string") }
        self = s
    }
}

extension Double: JSONCodable {
    public func toJSON() -> JSON { .double(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        switch json {
        case .double(let d): self = d
        case .float(let f): self = Double(f)
        case .uint(let u): self = Double(u)
        case .int(let i): self = Double(i)
        case .null where JSONDecoding.nullFloatsAsZero: self = 0
        default: throw .invalidType(json, expected: "f64")
        }
    }
}

extension Float: JSONCodable {
    public func toJSON() -> JSON { .float(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        switch json {
        case .double(let d): self = Float(d)
        case .float(let f): self = f
        case .uint(let u): self = Float(u)
        case .int(let i): self = Float(i)
        case .null where JSONDecoding.nullFloatsAsZero: self = 0
        default: throw .invalidType(json, expected: "f32")
        }
    }
}

/// serde's integer rules: an integer in range, else "invalid value"; a float or anything else is
/// "invalid type".
private func decodeInteger<T: FixedWidthInteger>(_ json: JSON, _ name: String) throws(JSONDecodeError) -> T {
    switch json {
    case .uint(let u):
        guard let v = T(exactly: u) else { throw JSONDecodeError("invalid value: integer `\(u)`, expected \(name)") }
        return v
    case .int(let i):
        guard let v = T(exactly: i) else { throw JSONDecodeError("invalid value: integer `\(i)`, expected \(name)") }
        return v
    default:
        throw .invalidType(json, expected: name)
    }
}

extension UInt8: JSONCodable {
    public func toJSON() -> JSON { .uint(UInt64(self)) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) { self = try decodeInteger(json, "u8") }
}

extension UInt16: JSONCodable {
    public func toJSON() -> JSON { .uint(UInt64(self)) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) { self = try decodeInteger(json, "u16") }
}

extension UInt32: JSONCodable {
    public func toJSON() -> JSON { .uint(UInt64(self)) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) { self = try decodeInteger(json, "u32") }
}

extension UInt64: JSONCodable {
    public func toJSON() -> JSON { .uint(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) { self = try decodeInteger(json, "u64") }
}

/// `usize`: Rust's word on the 64-bit targets deckcraft ships.
extension Int: JSONCodable {
    public func toJSON() -> JSON { .integer(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) { self = try decodeInteger(json, "usize or isize") }
}

extension Int8: JSONCodable {
    public func toJSON() -> JSON { .integer(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) { self = try decodeInteger(json, "i8") }
}

extension Int16: JSONCodable {
    public func toJSON() -> JSON { .integer(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) { self = try decodeInteger(json, "i16") }
}

extension Int32: JSONCodable {
    public func toJSON() -> JSON { .integer(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) { self = try decodeInteger(json, "i32") }
}

extension Int64: JSONCodable {
    public func toJSON() -> JSON { .integer(self) }
    public init(fromJSON json: JSON) throws(JSONDecodeError) { self = try decodeInteger(json, "i64") }
}

extension JSON: JSONCodable {
    public func toJSON() -> JSON { self }
    public init(fromJSON json: JSON) { self = json }
}

// MARK: - Containers

extension Optional: JSONEncodable where Wrapped: JSONEncodable {
    public func toJSON() -> JSON { self?.toJSON() ?? .null }
}

extension Optional: JSONDecodable where Wrapped: JSONDecodable {
    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        self = json.isNull ? nil : try Wrapped(fromJSON: json)
    }
}

extension Optional: JSONMissingValue {
    public static var whenMissing: Self { nil }
}

extension Array: JSONEncodable where Element: JSONEncodable {
    public func toJSON() -> JSON { .array(map { $0.toJSON() }) }
}

extension Array: JSONDecodable where Element: JSONDecodable {
    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        guard case .array(let items) = json else { throw .invalidType(json, expected: "a sequence") }
        var out: [Element] = []
        out.reserveCapacity(items.count)
        for item in items { out.append(try Element(fromJSON: item)) }
        self = out
    }
}

/// A Rust array `[T; N]`: a sequence of exactly `count` elements.
public func decodeFixedArray<T: JSONDecodable>(_ json: JSON, count: Int) throws(JSONDecodeError) -> [T] {
    let items = try [T](fromJSON: json)
    guard items.count == count else {
        throw JSONDecodeError("invalid length \(items.count), expected an array of length \(count)")
    }
    return items
}

/// The elements of a Rust tuple, which serde writes as a sequence of exactly `count` items.
public func tupleElements(_ json: JSON, count: Int) throws(JSONDecodeError) -> [JSON] {
    guard case .array(let items) = json else { throw .invalidType(json, expected: "a tuple of size \(count)") }
    guard items.count == count else {
        throw JSONDecodeError("invalid length \(items.count), expected a tuple of size \(count)")
    }
    return items
}

// MARK: - Structs

/// Reads the fields of a serde-derived struct.
public struct JSONFields: Sendable {
    public let object: JSONObject

    public init(_ json: JSON, _ typeName: String) throws(JSONDecodeError) {
        guard case .object(let o) = json else { throw .invalidType(json, expected: "struct \(typeName)") }
        object = o
    }

    public init(object: JSONObject) {
        self.object = object
    }

    public func has(_ key: String) -> Bool { object[key] != nil }

    /// A field without `#[serde(default)]`: an error when absent, unless the type is an `Option`.
    public func required<T: JSONDecodable>(_ key: String) throws(JSONDecodeError) -> T {
        guard let v = object[key] else {
            if let missing = T.self as? any JSONMissingValue.Type, let value = missing.whenMissing as? T {
                return value
            }
            throw .missingField(key)
        }
        return try Self.decode(v, key)
    }

    /// A field with a serde default (`#[serde(default)]` on it or its struct): `fallback` when absent.
    /// A present `null` is still an error for a non-`Option` type, as in serde.
    public func get<T: JSONDecodable>(_ key: String, default fallback: @autoclosure () -> T) throws(JSONDecodeError) -> T {
        guard let v = object[key] else { return fallback() }
        return try Self.decode(v, key)
    }

    /// Decodes `value` for `key`, naming the key in the error.
    public static func decode<T: JSONDecodable>(_ value: JSON, _ key: String) throws(JSONDecodeError) -> T {
        do {
            return try T(fromJSON: value)
        } catch {
            throw JSONDecodeError("\(error.message) (field `\(key)`)")
        }
    }

    /// The string under `key`, for internally and adjacently tagged enums.
    public func tag(_ key: String) throws(JSONDecodeError) -> String {
        guard let v = object[key] else { throw .missingField(key) }
        guard case .string(let s) = v else { throw .invalidType(v, expected: "a variant name") }
        return s
    }
}

extension JSONObject {
    /// Appends `key: value`.
    public mutating func put(_ key: String, _ value: some JSONEncodable) {
        append(key, value.toJSON())
    }

    /// Appends `key: value` unless `skip` holds: `#[serde(skip_serializing_if = ...)]`.
    public mutating func put(_ key: String, _ value: some JSONEncodable, skipIf skip: Bool) {
        if !skip { append(key, value.toJSON()) }
    }

    /// Appends `key: value` when the option holds a value: `skip_serializing_if = "Option::is_none"`.
    public mutating func putIfPresent<T: JSONEncodable>(_ key: String, _ value: T?) {
        if let value { append(key, value.toJSON()) }
    }

    /// Appends every entry of another object: `#[serde(flatten)]` and internally tagged variants.
    public mutating func merge(_ other: JSONObject) {
        for e in other.entries { append(e.key, e.value) }
    }
}

// MARK: - Unit-variant enums

/// An enum serde writes as a bare string (unit variants under `rename_all`). The raw values are the
/// serialised names.
public protocol JSONStringEnum: JSONCodable, RawRepresentable, CaseIterable where RawValue == String {}

extension JSONStringEnum {
    public func toJSON() -> JSON { .string(rawValue) }

    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        guard case .string(let s) = json else { throw .invalidType(json, expected: "a variant name") }
        guard let v = Self(rawValue: s) else {
            throw .unknownVariant(s, expected: Self.allCases.map(\.rawValue))
        }
        self = v
    }
}

// MARK: - Externally tagged enums

/// The variant name and content of an externally tagged enum value: `"name"` for a unit variant,
/// `{"name": content}` otherwise.
public func externalVariant(_ json: JSON) throws(JSONDecodeError) -> (name: String, content: JSON?) {
    switch json {
    case .string(let s):
        return (s, nil)
    case .object(let o) where o.count == 1:
        let e = o.entries[0]
        return (e.key, e.value)
    default:
        throw .invalidType(json, expected: "enum")
    }
}

/// `{"name": content}`.
public func externalVariant(_ name: String, _ content: JSON) -> JSON {
    .object(JSONObject([JSONObject.Entry(key: name, value: content)]))
}

// MARK: - Tuples

/// A Rust 2-tuple, which serde writes as a two-element sequence.
public struct Pair<A, B> {
    public var a: A
    public var b: B

    public init(_ a: A, _ b: B) {
        self.a = a
        self.b = b
    }
}

extension Pair: Sendable where A: Sendable, B: Sendable {}
extension Pair: Equatable where A: Equatable, B: Equatable {}
extension Pair: Hashable where A: Hashable, B: Hashable {}

extension Pair: JSONEncodable where A: JSONEncodable, B: JSONEncodable {
    public func toJSON() -> JSON { .array([a.toJSON(), b.toJSON()]) }
}

extension Pair: JSONDecodable where A: JSONDecodable, B: JSONDecodable {
    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let items = try tupleElements(json, count: 2)
        self.init(try A(fromJSON: items[0]), try B(fromJSON: items[1]))
    }
}

/// A Rust 3-tuple, which serde writes as a three-element sequence.
public struct Triple<A, B, C> {
    public var a: A
    public var b: B
    public var c: C

    public init(_ a: A, _ b: B, _ c: C) {
        self.a = a
        self.b = b
        self.c = c
    }
}

extension Triple: Sendable where A: Sendable, B: Sendable, C: Sendable {}
extension Triple: Equatable where A: Equatable, B: Equatable, C: Equatable {}
extension Triple: Hashable where A: Hashable, B: Hashable, C: Hashable {}

extension Triple: JSONEncodable where A: JSONEncodable, B: JSONEncodable, C: JSONEncodable {
    public func toJSON() -> JSON { .array([a.toJSON(), b.toJSON(), c.toJSON()]) }
}

extension Triple: JSONDecodable where A: JSONDecodable, B: JSONDecodable, C: JSONDecodable {
    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let items = try tupleElements(json, count: 3)
        self.init(try A(fromJSON: items[0]), try B(fromJSON: items[1]), try C(fromJSON: items[2]))
    }
}

// MARK: - Fixed-length arrays

extension JSONFields {
    /// A required `[T; N]` field.
    public func requiredFixed<T: JSONDecodable>(_ key: String, count: Int) throws(JSONDecodeError) -> [T] {
        guard let v = object[key] else { throw .missingField(key) }
        do {
            return try decodeFixedArray(v, count: count)
        } catch {
            throw JSONDecodeError("\(error.message) (field `\(key)`)")
        }
    }

    /// An `Option<[T; N]>` field: absent or `null` is nil, else exactly `count` elements.
    public func optionalFixed<T: JSONDecodable>(_ key: String, count: Int) throws(JSONDecodeError) -> [T]? {
        guard let v = object[key], !v.isNull else { return nil }
        do {
            return try decodeFixedArray(v, count: count)
        } catch {
            throw JSONDecodeError("\(error.message) (field `\(key)`)")
        }
    }

    /// An `Option<[T; N]>` field with a serde default: absent is `fallback`, `null` nil.
    public func getOptionalFixed<T: JSONDecodable>(_ key: String, count: Int, default fallback: @autoclosure () -> [T]?) throws(JSONDecodeError) -> [T]? {
        guard object[key] != nil else { return fallback() }
        return try optionalFixed(key, count: count)
    }

    /// A `[T; N]` field with a serde default.
    public func getFixed<T: JSONDecodable>(_ key: String, count: Int, default fallback: @autoclosure () -> [T]) throws(JSONDecodeError) -> [T] {
        guard let v = object[key] else { return fallback() }
        do {
            return try decodeFixedArray(v, count: count)
        } catch {
            throw JSONDecodeError("\(error.message) (field `\(key)`)")
        }
    }
}
