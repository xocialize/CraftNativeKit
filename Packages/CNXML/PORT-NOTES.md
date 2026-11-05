# CNXML — port notes

quick-xml 0.41.0 (MIT, © Johann Tuffe and the quick-xml contributors) reproduced over bytes in memory, as
gridcraft's `crates/xlsx` uses it: the pull reader, its errors and positions, namespace resolution and the event
writer. It is built without the `encoding` feature, which is how gridcraft builds it (`cargo tree -e features`:
default features only). Written for GridCraftNative's GCXLSX (Wave 3, 2026-11-05). DeckCraftNative's DCPPTX
`XML.swift` reproduces the same tokenizer inside its DOM builder; moving it onto CNXML is a later follow-up.

## Files

| Swift | quick-xml 0.41.0 | What |
|---|---|---|
| `Reader.swift` | `src/reader/mod.rs`, `state.rs`, `slice_reader.rs`, `src/parser/{element,pi,comment,dtd}.rs` | `XMLReader` (`Reader<&[u8]>`), `XMLReaderConfig`, `read_event`, `read_to_end`, the markup parsers |
| `Events.swift` | `src/events/mod.rs`, `src/name.rs` (`QName`) | `XMLEvent`, `XMLStart`, `XMLEnd`, `XMLText` (text, comment, DOCTYPE, CDATA, references), `XMLPI`, `XMLDecl`, `XMLQName` |
| `Attributes.swift` | `src/events/attributes.rs` | `XMLAttributes` (`IterState`, its error recovery and duplicate checks), `XMLAttribute` and `normalized_value` |
| `Escape.swift` | `src/escape.rs` | `escape`/`partial_escape`/`minimal_escape`, `unescape`, EOL and attribute-value normalisation (XML 1.0 and 1.1), `parse_number` |
| `Namespaces.swift` | `src/name.rs` (`NamespaceResolver`), `src/reader/ns_reader.rs` | `XMLNamespaceResolver`, `XMLResolveResult`, `XMLNSReader` |
| `Writer.swift` | `src/writer.rs` | `XMLWriter` (`Writer::new`, no indentation) |
| `Errors.swift` | `src/errors.rs`, `escape.rs`, `encoding.rs`, `attributes.rs`, `name.rs`; core's `Utf8Error`, `ParseIntError` | Every error with the text its `Display` prints; `RustUTF8Error.check` is `str::from_utf8`'s error |

## How it is shaped

- **One reader for both of quick-xml's.** gridcraft calls `read_event_into` on `Reader<&[u8]>` (the buffered path)
  in xml.rs and `read_event` (the slice path) elsewhere. Over a slice in memory the buffered source hands the
  parser the whole rest of the input as one chunk, so both give the same events, positions and errors. CNXML
  implements the slice path; the parsers' cross-chunk states (`UndecidedMarkup`, a comment end split over two
  chunks) can't arise and end the search.
- **Events are slices of the input.** `ArraySlice<UInt8>`s keep their input's indices: use `startIndex`, never an
  offset from 0. `bufferPosition` counts from after a removed UTF-8 BOM, as quick-xml's does; `input[inputStart +
  position]` is the byte at a position.
- **Errors.** `readEvent` throws `XMLError`; `"\(error)"` is quick-xml's `e.to_string()`. After a syntax error (or
  `Eof`) every later call returns `.eof`; after an ill-formed one (mismatched or unmatched end tag, unclosed
  reference, `--` in a comment, a DOCTYPE without a name) reading goes on, as quick-xml's does. Attribute steps are
  `Result<XMLAttribute, XMLAttrError>`; Rust's `.flatten()` is `compactMap { try? $0.get() }`.
- **Bounded.** Every step consumes at least one byte or ends the document, so reading is linear and nothing
  recurses. The duplicate-attribute check is quadratic up to 32 keys and hashed after, as quick-xml's is.
  Callers still bound depth and node counts (xlsx's `MAX_DEPTH`, `MAX_XML_NODES`).

## Oracle

GridCraftNative's `Tools/oracle/oracle.sh xml-vectors` builds `Tools/oracle/xml-vectors` (quick-xml `=0.41.0`,
gridcraft's release profile) and runs it over `inputs.py`'s documents: every XML part of the oracle corpus at the
pin, 123 hand-written constructs, truncations of three parts, seeded damage of twelve, and many-attribute,
many-namespace and deep documents. It writes `$GRIDCRAFT_FIXTURES/xml/<pin>/{inputs/,*.out,SHA256SUMS}`;
two runs give the same sums.

The six modes are the configurations crates/xlsx uses (`stream`: xml.rs's `parse_streaming`/`first_start`;
`default`: passthrough.rs, with the `Writer` output and the start tags rebuilt as `map_rel_ids` rebuilds them;
`ns`: xlsb.rs and ods.rs; `skip`: passthrough.rs's `read_to_end` scans), deckcraft's (`deck`), and one for
coverage (`misc`: expanded empty elements, trimming, comment checks, untrimmed end names). Each line is an event
with its positions, an error with its text and error position, an attribute step (without and with duplicate
checks, both normalisations), a text's decodings and escapes, a resolution, or a span.

`VectorTests` prints the same lines from CNXML and compares them. At 21b64df0: **713,833 lines over 762
documents, all equal** (stream 137,938, deck 137,938, default 148,997, misc 148,300, ns 136,551, skip 4,109). The
vectors reach every `SyntaxError`, every `IllFormedError` the reader raises, every `AttrError`, the escape and
character-reference errors, every namespace binding error and the declaration limit. The tests find the vectors
through `CNXML_VECTORS`, else GridCraftNative's fixtures at its pin, and say so and pass without them.

## Divergences

None in what the vectors check. Left out because nothing that uses CNXML calls them:

- the `encoding` feature (UTF-16 and legacy encodings: gridcraft's xml.rs converts UTF-16 itself, and GCXLSX does
  too);
- `Writer`'s indentation and `ElementWriter`; serde (de)serialisation; `html_attributes`; `read_text`;
  `BytesDecl`'s accessors (`version`, `encoding`, `standalone`).
