# CNZip — port notes

> Moved from DeckCraftNative (`Packages/DCZip`, module `DCZip`) at `5991914` on 2026-11-01. Tool paths below (`Tools/oracle/…`, `Tools/legacy/…`) are DeckCraftNative's.

`Zip.swift`, `Deflate.swift` and their tests are copied from PhotoCraftNative at `7fa4dcc`, from
`Packages/PCIO/Sources/PCIOCore/` and its `ZipTests.swift`. That code ports photocraft's `crates/format/src/zip.rs`
(MIT OR Apache-2.0) and adds ZIP64 and streaming. The only change is that `PCIOError` became `ZipError`. It has
24 tests.

- **Writing:** STORE, or DEFLATE when it saves space (`add(_:_:compress:)`). Classic layout, with ZIP64 only
  when an archive needs it.
- **Rust `zip` headers** (0.6.0, for GridCraftNative's XLSX writer): `ZipWriter(headers: .rustZip)` fills the
  version, flag and attribute fields as the Rust `zip` crate 3 does with default options (made by Unix 2.0, version
  2.0 for DEFLATE and 1.0 for STORE, the UTF-8 flag only on a non-ASCII name, mode 0644), and `addDeflated` always
  deflates, as that crate does. Measured on gridcraft's output (`rustZipHeaders`). The DEFLATE streams are still
  Compression's, not zlib-rs's, so the bytes inside differ (GridCraftNative decision 8). ZIP64 follows this
  package's rules, not the crate's, so archives past 4 GiB or 65,535 entries can differ in their ZIP64 fields.
- **Lazy local headers** (0.6.1): `ZipReader(bytes, lazyLocalHeaders: true)` reads only the central directory, as
  the Rust `zip` crate does, and reads each entry's local header (and fails a damaged one) when that entry is read;
  `dataStart(_:)` gives where its payload starts. GridCraftNative's package reader uses it, so a damaged entry costs
  only that entry, as upstream's does (its damage vectors). The default stays the eager check.
- **Reading:** STORE and DEFLATE, CRC-checked, bounded by `max`. With duplicate names, `find` returns the
  *first* entry. DCFormat looks entries up last-wins, as the Rust `zip` crate does.
- **Two-way fixes:** a fix made here should go to PhotoCraftNative too, and the other way round.
