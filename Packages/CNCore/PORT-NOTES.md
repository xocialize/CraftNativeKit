# CNCore — port notes

> Moved from DeckCraftNative (`Packages/DCCore`, module `DCCore`) at `5991914` on 2026-11-01. Tool paths below (`Tools/oracle/…`, `Tools/legacy/…`) are DeckCraftNative's.

CNCore holds what every package needs in order to behave like its Rust original. Upstream has no crate like
it: it stands in for serde, serde_json and Rust's numeric and string semantics. It has 20 tests.

## JSON (serde_json 1.0.154, zmij 1.0.23)

| File | Holds |
|---|---|
| `JSON.swift` | `JSON` (integers and floats kept apart, as serde_json does) and `JSONObject` (keys in insertion order) |
| `JSONWriter.swift` | `serde_json::to_vec`'s compact output. Floats in zmij's layout over Swift's shortest digits: fixed for decimal exponents −5…15 (f32: −6…12), otherwise `1.5e+16` / `1e-7` |
| `JSONParser.swift` | Strict, as `serde_json::from_slice` is: no trailing commas, no leading zeros, nesting limited to 128, lone surrogates refused, line and column in errors |
| `JSONCoding.swift` | serde-derive semantics: `JSONFields` (`required`, `get(default:)`, `requiredFixed`, `optionalFixed`, `tag`), `JSONStringEnum`, `externalVariant`, `Pair`/`Triple` for tuples, the `JSONDecoding.nullFloatsAsZero` mode |

**Measured:** 222,461 f64 values, 107,713 f32 values and 133 strings, all equal to serde_json's own output
(`DECKCRAFT_FIXTURES/json/`, written by `Tools/oracle/oracle.sh json-vectors`).

## Rust semantics

| File | Holds |
|---|---|
| `RustNumerics.swift` | `init(rustCast:)`, which saturates and maps NaN to 0, as `as` does; `clamped`, which keeps NaN; `rem` (Rust `%`); `rustMin`/`rustMax`, which ignore NaN; `toRadians`/`toDegrees`; `rustSignum` (`f64::signum`); `Collection.at` (Rust `get`) |
| `RustStrings.swift` | `rustTrim` (and the start/end variants), `rustLines`, `rustASCIILowercase`, `rustLowercase` (with final sigma), `rustUppercase`, `rustEqual` (scalar for scalar), `rustFixed` (`{:.N}`), `rustParseF64`/`rustParseF32` (`str::parse`: core's float grammar, which Swift's `Double(_:)` widens with hex, `nan(…)` and more) |
| `RustDisplay.swift` | `RustDisplayable` / `rustDisplay`: `format!("{}", v)` for floats, integers, strings, bools and characters; `rustHex` (`{:0NX}`) |

## Rust's `Display` for floats

`format!("{}", v)` is the shortest round-trip digits in plain decimal: no exponent at any magnitude,
`1` for `1.0`, `-0` for `-0.0`, `NaN`, `inf`. deckcraft-pptx writes every number in its XML this way.
`rustDisplay` builds the layout from Swift's shortest digits, with one fix: when the exact value is
the midpoint of two shortest candidates, Swift takes the even one and core's Dragon4 takes the larger
(`format_shortest` rounds up when `2·mant >= scale`). An exact integer test spots that midpoint, a
`Double(_:)` read-back confirms the larger candidate, and the larger is taken.

**Measured:** 222,470 f64 and 107,720 f32 values, every one equal to Rust's `{}`
(`DECKCRAFT_FIXTURES/json/display-*.txt`, written by `Tools/oracle/display-vectors/run.sh` from
json-vectors' inputs). Without the fix, the values with such a tie differ: Swift's digits give
`1658206780088562.2` where Rust prints `1658206780088562.3`.
