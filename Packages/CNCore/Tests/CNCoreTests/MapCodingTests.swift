import CNCore
import Testing

/// `BTreeMap`, `char` and `with` fields as serde_json writes and reads them.
@Suite struct MapCodingTests {
    @Test func mapsWriteTheirKeysInRustOrder() throws {
        let byNumber: [UInt32: String] = [10: "ten", 2: "two", 1: "one"]
        #expect(JSONWriter().string(byNumber.toJSON()) == #"{"1":"one","2":"two","10":"ten"}"#)
        // Strings by their UTF-8 bytes: "Z" < "a" < "é".
        let byName: [String: Int] = ["é": 3, "a": 2, "Z": 1]
        #expect(JSONWriter().string(byName.toJSON()) == #"{"Z":1,"a":2,"é":3}"#)
        #expect(try [UInt32: String](fromJSON: JSONParser.parse(#"{"10":"ten","1":"one"}"#)) == [1: "one", 10: "ten"])
    }

    @Test func integerKeysReadOnlyIntegers() {
        for bad in [#"{"x":1}"#, #"{" 1":1}"#, #"{"1.5":1}"#, #"{"-1":1}"#, #"{"4294967296":1}"#, #"{"":1}"#] {
            #expect(throws: JSONDecodeError.self, "\(bad)") { try [UInt32: Int](fromJSON: JSONParser.parse(bad)) }
        }
        #expect((try? [Int32: Int](fromJSON: JSONParser.parse(#"{"-1":1}"#))) == [-1: 1])
    }

    @Test func aRepeatedKeyKeepsItsLastValue() throws {
        #expect(try [String: Int](fromJSON: JSONParser.parse(#"{"a":1,"a":2}"#)) == ["a": 2])
    }

    @Test func charsAreOneCharacterStrings() throws {
        #expect(JSONWriter().string(Unicode.Scalar(0x1F600)!.toJSON()) == "\"😀\"")
        #expect(try Unicode.Scalar(fromJSON: .string("x")) == "x")
        #expect(throws: JSONDecodeError.self) { try Unicode.Scalar(fromJSON: .string("xy")) }
        #expect(throws: JSONDecodeError.self) { try Unicode.Scalar(fromJSON: .string("")) }
    }

    @Test func withFieldsUseTheirOwnReader() throws {
        let f = try JSONFields(JSONParser.parse(#"{"n":"7"}"#), "T")
        func digits(_ j: JSON) throws(JSONDecodeError) -> Int {
            guard case .string(let s) = j, let v = Int(s) else { throw JSONDecodeError("not digits") }
            return v
        }
        #expect(try f.required("n", with: digits) == 7)
        #expect(try f.get("m", default: 3, with: digits) == 3)
        #expect(throws: JSONDecodeError.self) { try f.required("m", with: digits) }
    }

    @Test func doubleRemEuclid() {
        #expect((-0.25).remEuclid(1.0) == 0.75 && (1.25).remEuclid(1.0) == 0.25)
    }
}

/// `serde_json::to_vec_pretty`'s layout.
@Suite struct PrettyJSONTests {
    @Test func prettyMatchesSerdeJSON() throws {
        let v = try JSONParser.parse(#"{"a":[1,{"b":[]},{}],"c":{"d":"x"},"e":[]}"#)
        let expected = """
            {
              "a": [
                1,
                {
                  "b": []
                },
                {}
              ],
              "c": {
                "d": "x"
              },
              "e": []
            }
            """
        #expect(JSONWriter(pretty: true).string(v) == expected)
        #expect(JSONWriter(pretty: true).string(.array([])) == "[]")
        #expect(JSONWriter().string(v) == #"{"a":[1,{"b":[]},{}],"c":{"d":"x"},"e":[]}"#)
    }
}

/// Rust trims whitespace scalar by scalar: a space that a combining mark follows is still trimmed, though Swift sees
/// the two as one character.
@Suite struct RustTrimTests {
    @Test func trimsScalarsNotCharacters() {
        let s = " \u{0301}x \u{0301}"
        #expect(rustTrim(s).unicodeScalars.elementsEqual("\u{0301}x \u{0301}".unicodeScalars))
        #expect(rustTrim("  ").isEmpty && rustTrim("").isEmpty)
        // The ASCII fast path agrees with the scalar-by-scalar rule at both ends.
        func reference(_ s: String) -> String {
            let u = s.unicodeScalars
            guard let a = u.firstIndex(where: { !$0.properties.isWhitespace }), let b = u.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
            return String(String.UnicodeScalarView(u[a ... b]))
        }
        for t in ["a", "ab", " a", "a ", "\u{0B}a", "a\u{0C}", "\u{85}a", "a\u{85}", "\u{A0}a\u{A0}", "a\u{2003}", "\u{3000}a",
                  "a b", "\ta\r\n", "x\u{0301}", "\u{0301}", "é", "日本 ", "\u{1F642}"] {
            #expect(rustTrim(t).unicodeScalars.elementsEqual(reference(t).unicodeScalars), "\(t.unicodeScalars.map { $0.value })")
        }
        #expect(rustTrimStart(Substring(" \u{0301}a ")).unicodeScalars.elementsEqual("\u{0301}a ".unicodeScalars))
        #expect(rustTrimEnd(Substring(" a\u{0301} \u{0301}")).unicodeScalars.elementsEqual(" a\u{0301} \u{0301}".unicodeScalars))
        #expect(rustTrimEnd(Substring(" a \u{2003}")).unicodeScalars.elementsEqual(" a".unicodeScalars))
        #expect(rustTrim("\u{3000}全角\u{3000}") == "全角")
    }
}
