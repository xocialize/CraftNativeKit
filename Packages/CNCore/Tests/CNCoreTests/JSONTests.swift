import CNCore
import CNTestSupport
import Foundation
import Testing

/// serde_json's output for generated values (`Tools/oracle/json-vectors`), in the fixtures.
private let vectors = Fixtures.root.appending(path: "json", directoryHint: .isDirectory)
private let haveVectors = FileManager.default.fileExists(atPath: vectors.appending(path: "f64.txt").path)

private func lines(_ name: String) throws -> [(Substring, Substring)] {
    let text = try String(contentsOf: vectors.appending(path: name), encoding: .utf8)
    return text.split(separator: "\n").compactMap { line in
        guard let space = line.firstIndex(of: " ") else { return nil }
        return (line[..<space], line[line.index(after: space)...])
    }
}

@Suite struct WriterTests {
    @Test func floatsLayOutAsZmij() {
        let cases: [(Double, String)] = [
            (960, "960.0"), (0, "0.0"), (-0.0, "-0.0"), (1.5, "1.5"), (0.1, "0.1"), (12_700, "12700.0"),
            (0.00001, "0.00001"), (0.000001, "1e-6"), (1e15, "1000000000000000.0"), (1e16, "1e+16"),
            (1.5e300, "1.5e+300"), (-0.27, "-0.27"), (5e-324, "5e-324"), (1.0 / 3.0, "0.3333333333333333"),
        ]
        for (v, s) in cases {
            #expect(ShortestFloat.format(v) == s, "\(v)")
        }
        #expect(ShortestFloat.format(Float(0.000001)) == "0.000001")
        #expect(ShortestFloat.format(Float(1e13)) == "1e+13")
    }

    @Test func nonFiniteIsNullOrZero() {
        let v = JSON.array([.double(.nan), .double(.infinity), .float(-.infinity)])
        #expect(JSONWriter().string(v) == "[null,null,null]")
        #expect(JSONWriter(nonFiniteAsZero: true).string(v) == "[0.0,0.0,0.0]")
    }

    @Test func objectsKeepOrderAndIntegersStayIntegers() {
        let o = JSON.object(JSONObject(["b": .uint(1), "a": .int(-2), "c": .string("x\"y"), "d": .null]))
        #expect(JSONWriter().string(o) == #"{"b":1,"a":-2,"c":"x\"y","d":null}"#)
    }

    @Test(.enabled(if: haveVectors, "no json vectors: run Tools/oracle/oracle.sh json-vectors"))
    func everyF64MatchesSerdeJSON() throws {
        var mismatches: [String] = []
        for (hex, expected) in try lines("f64.txt") {
            guard let bits = UInt64(hex, radix: 16) else { continue }
            let v = Double(bitPattern: bits)
            // The generator's overflowing products: serde_json writes `null`, which the writer handles apart.
            guard v.isFinite else { continue }
            let got = ShortestFloat.format(v)
            if got != expected, mismatches.count < 10 { mismatches.append("\(hex): \(got) ≠ \(expected)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test(.enabled(if: haveVectors, "no json vectors: run Tools/oracle/oracle.sh json-vectors"))
    func everyF32MatchesSerdeJSON() throws {
        var mismatches: [String] = []
        for (hex, expected) in try lines("f32.txt") {
            guard let bits = UInt32(hex, radix: 16) else { continue }
            let got = ShortestFloat.format(Float(bitPattern: bits))
            if got != expected, mismatches.count < 10 { mismatches.append("\(hex): \(got) ≠ \(expected)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test(.enabled(if: haveVectors, "no json vectors: run Tools/oracle/oracle.sh json-vectors"))
    func everyStringMatchesSerdeJSON() throws {
        for (hex, expected) in try lines("strings.txt") {
            var bytes: [UInt8] = []
            if hex != "-" {
                var i = hex.startIndex
                while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), let b = UInt8(hex[i ..< j], radix: 16) {
                    bytes.append(b)
                    i = j
                }
            }
            let s = String(decoding: bytes, as: UTF8.self)
            #expect(JSONWriter().string(.string(s)) == String(expected), "\(hex)")
            #expect(try JSONParser.parse(String(expected)) == .string(s))
        }
    }
}

@Suite struct ParserTests {
    @Test func readsWhatSerdeWrites() throws {
        let text = #"{"a":[1,-2,3.5,1e-7,true,null],"b":{"c":"\u00e9\ud83c\udf89"}}"#
        let v = try JSONParser.parse(text)
        #expect(v["a"] == .array([.uint(1), .int(-2), .double(3.5), .double(1e-7), .bool(true), .null]))
        #expect(v["b"]?["c"] == .string("é🎉"))
        // Re-serialising gives the same bytes, except the escapes serde_json wouldn't write.
        #expect(JSONWriter().string(try JSONParser.parse(#"{"x":[1.0,0.5,"a"]}"#)) == #"{"x":[1.0,0.5,"a"]}"#)
    }

    @Test(arguments: [
        "", "[1,]", "{\"a\":1,}", "01", "1.", ".5", "-", "[1 2]", "{a:1}", "\"\\x\"", "\"\u{01}\"",
        "\"\\ud800\"", "nul", "[1]x", "// c\n1", "NaN", "1e400",
    ])
    func refusesWhatSerdeRefuses(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(text) }
    }

    @Test func boundsNesting() {
        let ok = String(repeating: "[", count: 128) + String(repeating: "]", count: 128)
        #expect((try? JSONParser.parse(ok)) != nil)
        let deep = String(repeating: "[", count: 129) + String(repeating: "]", count: 129)
        #expect(throws: JSONParseError.self) { try JSONParser.parse(deep) }
    }

    @Test func hugeIntegersBecomeFloats() throws {
        #expect(try JSONParser.parse("18446744073709551615") == .uint(.max))
        #expect(try JSONParser.parse("18446744073709551616") == .double(18_446_744_073_709_551_616))
        #expect(try JSONParser.parse("-9223372036854775808") == .int(.min))
    }

    @Test func reportsLineAndColumn() {
        do {
            _ = try JSONParser.parse("{\n  \"a\": x\n}")
            Issue.record("parsed")
        } catch {
            #expect(error.line == 2)
            #expect(error.column == 8)
        }
    }
}

@Suite struct CodingTests {
    @Test func integersFollowSerde() throws {
        #expect(try UInt8(fromJSON: .uint(255)) == 255)
        #expect(throws: JSONDecodeError.self) { try UInt8(fromJSON: .uint(256)) }
        #expect(throws: JSONDecodeError.self) { try UInt8(fromJSON: .int(-1)) }
        #expect(throws: JSONDecodeError.self) { try UInt32(fromJSON: .double(1)) }
        #expect(try Double(fromJSON: .uint(3)) == 3)
        #expect(try Int32(fromJSON: .int(-5)) == -5)
    }

    @Test func fieldsDefaultAndOptionsGoMissing() throws {
        let f = try JSONFields(.object(JSONObject(["a": .uint(1), "n": .null])), "T")
        let a: UInt32 = try f.required("a")
        let b: Double? = try f.required("b")
        let c: Bool = try f.get("c", default: true)
        let n: String? = try f.required("n")
        #expect(a == 1 && b == nil && c && n == nil)
        #expect(throws: JSONDecodeError.missingField("z")) { let _: UInt32 = try f.required("z") }
        #expect(throws: JSONDecodeError.self) { let _: Bool = try f.get("n", default: false) }
    }

    @Test func rustCastsSaturate() {
        #expect(UInt8(rustCast: 300.0) == 255)
        #expect(UInt8(rustCast: -4.0) == 0)
        #expect(UInt8(rustCast: Double.nan) == 0)
        #expect(UInt8(rustCast: 254.9) == 254)
        #expect(Int32(rustCast: -1e20) == .min)
        #expect(Int64(rustCast: 1e300) == .max)
        #expect(Double.nan.clamped(0, 1).isNaN)
        // Signed zeros as Rust treats them on Apple silicon.
        #expect((-0.0).clamped(0, 1).sign == .minus)
        #expect((0.0).rustMin(-0.0).sign == .minus)
        #expect((-0.0).rustMax(0.0).sign == .plus)
        #expect(Double.nan.rustMax(2) == 2 && (3.0).rustMin(.nan) == 3)
        #expect((-7.5).rem(2) == -1.5)
    }
}
