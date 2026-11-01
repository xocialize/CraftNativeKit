import CNCore
import CNTestSupport
import Foundation
import Testing

/// Rust's `format!("{}", v)` for the json-vectors floats (`Tools/oracle/display-vectors`), in the fixtures.
private let vectors = Fixtures.root.appending(path: "json", directoryHint: .isDirectory)
private let haveVectors = FileManager.default.fileExists(atPath: vectors.appending(path: "display-f64.txt").path)

private func lines(_ name: String) throws -> [(Substring, Substring)] {
    let text = try String(contentsOf: vectors.appending(path: name), encoding: .utf8)
    return text.split(separator: "\n").compactMap { line in
        guard let space = line.firstIndex(of: " ") else { return nil }
        return (line[..<space], line[line.index(after: space)...])
    }
}

@Suite struct RustDisplayTests {
    @Test func floatsPrintAsRustDisplays() {
        let cases: [(Double, String)] = [
            (1, "1"), (0, "0"), (-0.0, "-0"), (1.5, "1.5"), (0.1, "0.1"), (12_700, "12700"), (-0.27, "-0.27"),
            (1e21, "1000000000000000000000"), (1e-7, "0.0000001"), (1.0 / 3.0, "0.3333333333333333"),
            (.nan, "NaN"), (-.nan, "NaN"), (.infinity, "inf"), (-.infinity, "-inf"), (5e-324, "0." + String(repeating: "0", count: 323) + "5"),
            (123.456, "123.456"), (100, "100"),
        ]
        for (v, s) in cases {
            #expect(v.rustDisplay == s, "\(v)")
        }
        #expect(Float(0.1).rustDisplay == "0.1")
        #expect(Float(16_777_216).rustDisplay == "16777216")
        #expect(Float(-0.0).rustDisplay == "-0")
    }

    @Test func integersBoolsAndStrings() {
        #expect(42.rustDisplay == "42")
        #expect((-7 as Int32).rustDisplay == "-7")
        #expect(UInt64.max.rustDisplay == "18446744073709551615")
        #expect(true.rustDisplay == "true")
        #expect("x&y".rustDisplay == "x&y")
    }

    @Test func hexPadsLikeRust() {
        #expect(rustHex(0xAB as UInt32, width: 8) == "000000AB")
        #expect(rustHex(0x1_2345_6789 as UInt64, width: 4) == "123456789")
        #expect(rustHex(255 as UInt8, width: 4, uppercase: false) == "00ff")
    }

    @Test(.enabled(if: haveVectors, "no display vectors: run Tools/oracle/display-vectors"))
    func everyF64MatchesRustDisplay() throws {
        var mismatches: [String] = []
        var n = 0
        for (hex, expected) in try lines("display-f64.txt") {
            guard let bits = UInt64(hex, radix: 16) else { continue }
            n += 1
            let got = Double(bitPattern: bits).rustDisplay
            if got != expected, mismatches.count < 10 { mismatches.append("\(hex): \(got) ≠ \(expected)") }
        }
        #expect(n > 200_000)
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test(.enabled(if: haveVectors, "no display vectors: run Tools/oracle/display-vectors"))
    func everyF32MatchesRustDisplay() throws {
        var mismatches: [String] = []
        var n = 0
        for (hex, expected) in try lines("display-f32.txt") {
            guard let bits = UInt32(hex, radix: 16) else { continue }
            n += 1
            let got = Float(bitPattern: bits).rustDisplay
            if got != expected, mismatches.count < 10 { mismatches.append("\(hex): \(got) ≠ \(expected)") }
        }
        #expect(n > 100_000)
        #expect(mismatches.isEmpty, "\(mismatches)")
    }
}

@Suite struct RustParseTests {
    @Test func floatGrammarIsCores() {
        let ok: [(String, Double)] = [("1", 1), ("1.", 1), (".5", 0.5), ("+1.5", 1.5), ("-.5e-3", -0.0005), ("1E3", 1000), ("1e+3", 1000), ("007", 7), ("1e-400", 0)]
        for (s, v) in ok {
            #expect(rustParseF64(s) == v, "\(s)")
        }
        #expect(rustParseF64("1e400") == .infinity)
        #expect(rustParseF64("-Infinity") == -.infinity)
        #expect(rustParseF64("NaN")?.isNaN == true)
        for s in ["", ".", "+", "e5", "1e", "1e+", "0x1p3", "nan(1)", " 1", "1 ", "1_0", "1.2.3", "infinit", "--1"] {
            #expect(rustParseF64(s) == nil, "\(s)")
        }
        #expect(rustParseF32("0.1") == Float(0.1))
    }
}
