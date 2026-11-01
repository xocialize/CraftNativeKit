# CNZip — port notes

> Moved from DeckCraftNative (`Packages/DCZip`, module `DCZip`) at `5991914` on 2026-11-01. Tool paths below (`Tools/oracle/…`, `Tools/legacy/…`) are DeckCraftNative's.

`Zip.swift`, `Deflate.swift` and their tests are copied from PhotoCraftNative at `7fa4dcc`, from
`Packages/PCIO/Sources/PCIOCore/` and its `ZipTests.swift`. That code ports photocraft's `crates/format/src/zip.rs`
(MIT OR Apache-2.0) and adds ZIP64 and streaming. The only change is that `PCIOError` became `ZipError`. It has
24 tests.

- **Writing:** STORE, or DEFLATE when it saves space (`add(_:_:compress:)`). Classic layout, with ZIP64 only
  when an archive needs it.
- **Reading:** STORE and DEFLATE, CRC-checked, bounded by `max`. With duplicate names, `find` returns the
  *first* entry. DCFormat looks entries up last-wins, as the Rust `zip` crate does.
- **Two-way fixes:** a fix made here should go to PhotoCraftNative too, and the other way round.
