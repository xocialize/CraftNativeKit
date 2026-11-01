# CNMetafile — port notes

> Moved from DeckCraftNative (`Packages/DCMetafile`, module `DCMetafile`) at `5991914` on 2026-11-01. Tool paths below (`Tools/oracle/…`, `Tools/legacy/…`) are DeckCraftNative's.

Port of deckcraft `crates/metafile` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors) at the
pin in `Tools/oracle/pin.env` (27009cd9). WMF, EMF and EMF+ are read into a neutral vector model and placed
on a target. L0: depends on CNCore only. CoreGraphics and ImageIO are used for compressed EMF+ bitmaps and
for the `cg…` conveniences; nothing imports AppKit.

## File map

| Swift | Rust | Notes |
|---|---|---|
| `Bytes.swift` | `bytes.rs` | Bounded little-endian reads over a shared buffer. |
| `Geom.swift` | `geom.rs` | `P`, `Op`, rectangles, round rectangles, ellipses, arcs, subpaths. Also the Rust float helpers the port needs: `sinCos`, `remEuclid`, `asUsize`, `rustSum`, `Float.rustMin/rustMax`. |
| `Text.swift` | `text.rs` | `MetafileFont`, `MetafileText`, `MetafileHAlign`/`VAlign`, TA/ETO constants, code pages and UTF-16 decoding. |
| `Clip.swift` | `clip.rs` | Rectangle clip regions. |
| `ClipRect.swift` | `cliprect.rs` | Convex polygon clipping (EMF+). |
| `DIB.swift` | `dib.rs` | DIB decoding, blits, raster ops, alpha. Indexed DIBs go through a 256-entry lookup (same output). |
| `Canvas.swift` | `canvas.rs` | Mapping, objects, DC stack, paths, brushes, text placement. |
| `EMF.swift` | `emf.rs` | |
| `WMF.swift` | `wmf.rs` | |
| `EMFPlus.swift` | `emfplus.rs` | |
| `ImageDecode.swift` | `emfplus.rs` `decode_compressed` | ImageIO instead of the `image` crate (see below). |
| `Metafile.swift` | `lib.rs` | Entry points, the public model, `build`. |
| `Place.swift` | `place.rs` | Placement, plus the kurbo pieces it uses (Affine, Rect, BezPath, cubic bounding boxes with `solve_quadratic`). |

Tests: `RecordTests.swift`, `BitmapTextTests.swift`, `ClipPlusTests.swift` hold every test of `tests.rs` (108)
and the four in-file tests of `clip.rs`, one Swift test per Rust test with the same name in camel case.
`Support.swift` has the record builders. `OracleTests.swift` is the parity test (below).

## Public API

```swift
Metafile.isMetafile(_ bytes: [UInt8]) -> Bool
Metafile.parse(_ bytes: [UInt8]) throws(MetafileError) -> MetafilePicture   // .notMetafile, .badHeader, .noRecords
Metafile.symbolCharset: UInt8            // SYMBOL_CHARSET (2)
Metafile.maxBitmapSide: UInt32           // MAX_BITMAP_SIDE (30_000)

MetafilePicture { width: Float, height: Float, items: [MetafileItem] }
  .hasSize: Bool
  .fit(_ r: MetafileRect, crop: SIMD4<Float>) -> MetafileAffine?
  .place(_ r: MetafileRect, crop: SIMD4<Float>) -> [MetafilePlacedItem]
MetafileItem: .path(segs:fill:stroke:evenOdd:region:), .bitmap(rect:width:height:rgba:region:),
              .pattern(segs:evenOdd:tile:region:), .text(MetafileText)
  mutating .takePixels() -> (width: UInt32, height: UInt32, rgba: [UInt8])?
MetafileSeg: .move, .line, .cubic, .close (Float)
MetafileStroke { color, width: Float }
MetafileTile (final class: shared by fills of one brush; key a cache by ObjectIdentifier)
  { width, height: UInt32, rgba: [UInt8], cell, origin: SIMD2<Float> }
MetafileText { transform: [Double] (6, kurbo order), text, dx: [Float], font: MetafileFont, color,
               background: MetafileColor?, hAlign, vAlign, clip: SIMD4<Float>?, region: [SIMD4<Float>]? }
MetafileFont { family, height, width: Float, weight: UInt16, italic, underline, strike, charset: UInt8 }
MetafileColor = SIMD4<UInt8> (straight RGBA)

MetafilePlacedItem:
  .path(path: MetafilePath, fill: MetafileColor?, stroke: (color: MetafileColor, width: Double)?, evenOdd: Bool, region: MetafilePath?)
  .bitmap(index: Int, rect: MetafileRect, region: MetafilePath?)
  .pattern(index: Int, path: MetafilePath, evenOdd: Bool, tile: MetafileAffine, region: MetafilePath?)
  .text(index: Int, transform: MetafileAffine, clip: MetafileRect?, region: MetafilePath?)
MetafilePath { elements: [MetafilePathElement] }   .cgPath, .boundingBox
MetafileAffine { coeffs: [Double] }                .cgAffineTransform, .determinant, .apply, *
MetafileRect { x0, y0, x1, y1 }                    .cgRect, .width, .height
```

The renderer does what deckcraft's `crates/render/src/metafile.rs` does: `parse`, `hasSize`, `takePixels` on each
item, `place`, then `items[index]` for bitmaps, patterns and text.

## Divergences

- **Compressed EMF+ bitmaps** are decoded with ImageIO. The limits are the crate's (32768 a side, 40 M pixels,
  checked from the header first). 8-bit RGB, RGBA and grey images are read as decoded, with no colour
  matching, as the `image` crate does; other layouts (16-bit, CMYK, indexed that ImageIO keeps indexed) are
  drawn into an RGBA8 context and un-premultiplied, so they can differ in the last bit. JPEG's YCbCr
  conversion is Apple's, not zune-jpeg's, and may differ by one.
- **Nesting depth.** deckcraft counts nested metafile images in a thread-local; here the depth is a parameter
  (`EMF.parse(_:depth:)`, `Plus(depth:)`). Same limit (3).
- **Tile sharing.** `Arc::strong_count` decides whether a pattern fill's tile counts against the byte budget;
  here `RawTile.held` is set when a pattern brush caches its plain tile. `build` keeps shared tiles shared
  (`MetafileTile` identity), keyed by `ObjectIdentifier`.
- **Placed regions** are values (`MetafilePath`), not `Arc<BezPath>`; `place` caches the last region by value
  rather than by pointer (same output).
- **Stable sort** of linear-gradient stops by `total_cmp` is written out (Swift's sort is not documented as
  stable).
- **sin/cos.** deckcraft's release build computes the sine and cosine of one value in one `__sincos_stret`
  call (LLVM merges the pair), which rounds differently from separate calls for a small share of inputs. The
  port calls `sinCos` (`__sincos_stret`) wherever the Rust takes both of one value. The oracle's
  `wmf-escapements` case fails with separate `sin`/`cos` and passes with `sinCos`.

## Oracle

`Tools/oracle/metafile-vectors` (own `[workspace]`, path dependency on the pinned crate, deckcraft's release
profile, deckcraft's `Cargo.lock`) builds 23 files — the crate's test shapes plus arcs, rotations, escapements,
text, brushes, clips, raw and nested images — and 302 deterministic mutations of them (changed bytes, an 0xFF
tail, a truncation), then writes each `.bin` and a dump of the parsed model, the placed items and `takePixels`,
every float as its bit pattern, to `../DeckCraftNative-Fixtures/metafile/`. `OracleTests.swift` rebuilds every
dump and requires identical text; it skips without the fixtures. All 325 cases match.

```sh
# or: Tools/oracle/oracle.sh metafile-vectors
cd Tools/oracle/metafile-vectors
PATH=/opt/homebrew/opt/rustup/bin:$PATH CARGO_TARGET_DIR=~/Library/Caches/DeckCraftNative/cargo-target \
  cargo run -q --release -- ../../../../DeckCraftNative-Fixtures/metafile
```

## Notes

- `patternBrushPixelsCountAgainstTheByteBudget` takes about 7 s in a debug build (it decodes 1024 DIBs of
  256 × 256); the rest of the suite runs in about 1 s.
- `Float.rustMin/rustMax` and `Int`/`Int64` saturating adds are internal here; they belong in CNCore if another
  port needs them.

## Pin move 88c2ceff → a3fbf029

- **Ported: EMF+ region path reads are bounded** (d9f90c51). The fix has two parts:
  - A path node is now parsed from its own `size` bytes only. Before, it read to the end of the record, so a
    path claiming more points than it holds could take them from the next node. A path node under 12 bytes,
    or a path that doesn't parse, makes the whole region fail; before, it became an empty area.
  - The nodes and path points of one region are counted together, sibling branches included, and capped at
    `maxPoints`.

  Both tests are ported in `ClipPlusTests`.
- **No port needed:** f441ea93 (the Clippy split of `record`), checked arm by arm. The `emfplus.rs` change in
  505a6f28 is the same condition rewritten by De Morgan's law.
