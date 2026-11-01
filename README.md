# CraftNativeKit

The base packages the native Swift ports of the storytold Crafting Apps share. macOS 26+, Apple Silicon, Swift 6.

| Product | What it is | First written for |
|---|---|---|
| `CNCore` | serde_json-exact JSON (value, writer, parser, serde-derive coding) and Rust's numeric and string semantics | DeckCraftNative, Wave 1 |
| `CNZip` | ZIP read and write, ZIP64 included; raw DEFLATE through the Compression framework | PhotoCraftNative, then DeckCraftNative |
| `CNCFB` | The Compound File Binary format ([MS-CFB]), read and written | DeckCraftNative (legacy `.ppt`, encryption) |
| `CNOffCrypto` | Password-protected OOXML ([MS-OFFCRYPTO]): Agile and Standard, read and written | DeckCraftNative |
| `CNMetafile` | EMF, EMF+ and WMF read into a neutral vector model | DeckCraftNative (deckcraft-metafile, itself from WordCraft) |

`Tools/port/serde2swift.py` generates Swift value types with serde-exact JSON coding from Rust sources; the
generated files import `CNCore`.

## Consumers

- [DeckCraftNative](https://github.com/xocialize/DeckCraftNative): the deckcraft port.
- [Marquee Documents](https://github.com/Mountain-View-Staging/MarqueeDocuments): the WordCraft port.

Depend on it by URL:

```swift
.package(url: "https://github.com/xocialize/CraftNativeKit.git", from: "0.1.0"),
```

## Rules

These packages read hostile input (documents people receive), so the never-crash rule of the ports applies here
first: no `!`, `try!`, `fatalError`, `precondition`, `as!` or unchecked subscripts on input-derived indices in
production targets; input-derived numbers are checked; recursion and allocations are bounded. A crash fix lands with
a regression test. Nothing here imports AppKit or SwiftUI.

A change here is a change in every consumer. Run the whole test suite, then bump the version (semver: a source
change a consumer must follow is a minor bump while the version is 0.x) and update consumers on purpose.

## Tests and fixtures

```bash
swift test
```

Some tests read vectors written by DeckCraftNative's oracle tools (serde_json's floats, Rust's float Display,
deckcraft-metafile's dumps, the legacy and encrypted files). They look in `CRAFTNATIVEKIT_FIXTURES`, then
`DECKCRAFT_FIXTURES`, then `../DeckCraftNative-Fixtures`. Each package's `PORT-NOTES.md` says how its vectors are made.

## Licence

MIT OR Apache-2.0, at your option ([LICENSE-MIT](LICENSE-MIT), [LICENSE-APACHE](LICENSE-APACHE), [NOTICE](NOTICE)).
Ported code names its source file and licence in its header; upstream licence texts are in `LICENSES/`.
