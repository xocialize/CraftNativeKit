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
| `Place.swift` | `place.rs` | Placement, plus the kurbo pieces it uses (Affine, Rect, BezPath, cubic bounding boxes with `solve_quadratic`). WordCraft's `crop_window` and crop rule. |
| `TextRun.swift` | WordCraft `lib.rs` `Text`, `place.rs` `Text::layout` | WordCraft's view of a text run, derived from `MetafileText` (see the WordCraft merge). |

Tests: `RecordTests.swift`, `BitmapTextTests.swift`, `ClipPlusTests.swift` hold every test of `tests.rs` (108)
and the four in-file tests of `clip.rs`, one Swift test per Rust test with the same name in camel case.
`Support.swift` has the record builders. `OracleTests.swift` is the parity test (below). `WordCraftTests.swift` holds
the tests that exist only in WordCraft's crate (see the WordCraft merge).

## Public API

```swift
Metafile.isMetafile(_ bytes: [UInt8]) -> Bool
Metafile.parse(_ bytes: [UInt8]) throws(MetafileError) -> MetafilePicture   // .notMetafile, .badHeader, .noRecords
Metafile.symbolCharset: UInt8            // SYMBOL_CHARSET (2)
Metafile.maxBitmapSide: UInt32           // MAX_BITMAP_SIDE (30_000)

MetafilePicture { width: Float, height: Float, items: [MetafileItem] }
  .hasSize: Bool
  .fit(_ r: MetafileRect, crop: SIMD4<Float>, rule: MetafileCropRule = .deckcraft) -> MetafileAffine?
  .place(_ r: MetafileRect, crop: SIMD4<Float>, rule: MetafileCropRule = .deckcraft) -> [MetafilePlacedItem]
MetafileCropRule: .deckcraft, .wordCraft
Metafile.cropWindow(_ crop: SIMD4<Float>) -> SIMD4<Double>   // WordCraft's crop_window: [left, top, width, height]
Metafile.minVisibleCrop: Double          // 0.005
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
MetafileText.run: MetafileTextRun?       // WordCraft's `Text`
MetafileTextRun { text, x, y, size: Float, cell: Bool, font: String, bold, italic, color, angle: Float, hAlign, vAlign,
                  dx: [Float] }
  .placement(_ fit: MetafileAffine) -> MetafileAffine?        // WordCraft's PlacedItem::Text tf
  .layout(upem:ascent:descent:glyphs:) -> MetafileTextLayout?  // glyphs: (cluster: UTF-8 offset, advance, xOffset, yOffset)
MetafileTextLayout { em, baseline: Double, glyphs: [SIMD2<Double>] }
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

## WordCraft merge (2026-11-01)

deckcraft's `crates/metafile` forked from WordCraft's on 2026-10-12. WordCraft then landed five metafile commits that
deckcraft has not taken (its `origin/main` doesn't have them either). They are ported here from the WordCraft checkout
at `fd7f6621` (MIT OR Apache-2.0, © ArtCraft Team and the WordCraft contributors), so Marquee Documents draws
metafiles the way WordCraft does while DeckCraftNative keeps deckcraft's output. Each changed file names its WordCraft
source in its header.

| WordCraft commit | What | Here |
|---|---|---|
| `45d2546b` | WMF handle table finds its lowest free slot without scanning | `Canvas.objects` keeps a free-slot set (`SlotSet`: 64 words of bits and a summary word, for the 4096-slot cap; WordCraft uses a `BTreeSet`). Same slots as the scan. |
| `45d2546b` | Shape ops mapped in place | `Canvas.shape` takes its ops `consuming` and maps them in place. |
| `45d2546b` | Cropped DIB decode (`decode_clip`) | `DIB.decodeClip` validates the whole DIB, then decodes only the rows and columns the source rectangle covers; the EMF and WMF blits use it. `DIB.clipRect` is the shared clip arithmetic. `decode` and `clipBlit` stay for pattern brushes and EMF+ images, so `Rgba.bottomUp` stays (WordCraft dropped it). Output unchanged: `prepare` is per pixel, so preparing the cropped part equals cropping the prepared whole. |
| `6931b8db` | EMF text (EXTTEXTOUTW) | Reconciled, not duplicated: see below. |
| `0cca2f7d`, `fc5063c3` | A sliver crop is drawn at the file's size, keeping at least 0.5% of an axis (`crop_window`) | `Metafile.cropWindow`, and `fit`/`place` take `rule: .wordCraft`. The default stays `.deckcraft` (sides clamped to 0–0.95, at least 5% shown). |
| `c98efffc` | Empty polygon groups reserve nothing | `subpaths` reserves exactly the ops it emits. |

**Text.** deckcraft's reader already parses every record the WordCraft commit reads (EXTCREATEFONTINDIRECTW,
SETTEXTALIGN, SETTEXTCOLOR, EXTTEXTOUTW, the stock fonts, the DC stack) and more (EXTTEXTOUTA, SMALLTEXTOUT, WMF
TEXTOUT/EXTTEXTOUT, the background, ETO_CLIPPED, clip regions). So there is one parser and one model (`MetafileText`),
and `MetafileText.run` derives WordCraft's `Text` from it: the reference point and baseline angle from `transform`, the
size as the font height times the scale across the baseline (a height of 0 is WordCraft's 16 units; positive is a cell
height), advances times the scale along it, the face (Arial when none), bold from weight 600, and trailing NULs dropped
with their advances. `MetafileTextRun.layout` is WordCraft's `Text::layout` (glyph clusters are UTF-8 byte offsets, as
its shaper gives them) and `placement` is the transform WordCraft's `PlacedItem::Text` carries. Where the two readers
still differ on the same file, deckcraft's behaviour is what the model holds:

- **Text inside a path bracket** is drawn here; WordCraft drops it.
- **TA_UPDATECP** moves the current point by the advance along the escapement and the alignment here (estimated from
  the height without a dx array); WordCraft moves it by the dx sum along logical x only.
- **Mirroring mappings.** Glyphs are never mirrored here (the baseline of an x-mirrored mapping runs left to right);
  WordCraft's angle follows the device direction (π for an x-mirrored mapping).
- **Non-uniform frames.** The run's angle is taken in picture space; WordCraft's is the device angle, which differs
  when the frame scales x and y differently and the text is rotated.

None of these has an option yet: each needs a parse option threaded through `Canvas`, and no WordCraft test covers
them. Add one when Marquee Documents' layout parity needs it.

**Byte budget.** WordCraft's `c98efffc` also makes `Canvas::push` charge each item's capacity rather than its length.
Here items are still charged by length (deckcraft's rule, so the oracle's cut points hold). Rust's `Vec` growth slack
can't be reproduced by Swift's arrays, so a capacity rule wouldn't give WordCraft's cut points either; exact-sized
`subpaths` closes the hole the commit found (room reserved for empty groups that the budget never saw).

**Tests.** WordCraft's crate has 65 tests; 57 share a name with deckcraft's and 8 are its own.

- The 8 are in `WordCraftTests.swift`: `handleTablePicksTheSameSlotsAsTheFirstFreeScan`,
  `creatingIntoAFullTableDoesNotScanIt`, `decodeClipMatchesDecodeThenClipBlit` (18,816 cases, bit-exact against
  `decode` + `clipBlit`), `decodeClipRejectsWhatDecodeRejected`, `decodeClipDecodesOnlyTheCroppedPixels` (counted
  through an `inout` counter instead of a thread-local), `cropWindowKeepsASliverAndStaysFinite`,
  `theNarrowestCropOnTheLargestFrameKeepsItsContent` (both with `rule: .wordCraft`), `emptyPolyGroupsReserveNothing`
  (Swift may round a reservation up to its allocation, so the capacity bounds are ≤ 8, not exact). Beside them:
  `cropRulesDifferOnlyOnSlivers`, and four tests of the text run, its layout and its placement.
- 48 shared tests have identical bodies. The other 9 (`wmfStretchdibFlipsBottomUpRows`,
  `emfStretchdibitsFlipsAndFitsFrame`, `wmfStretchdibClippedSourceKeepsItsPlace`, `canvasStopsAtTheByteBudget`,
  `wmfDibbitbltCopiesTheDibAtItsDestination`, `flipToleratesAShortPixelBuffer`,
  `placeFitsTheFrameScalesStrokesAndDropsFarPaths`, `placeKeepsOnlyFiniteBoundedBitmapsWithArea`,
  `takePixelsReturnsOnlyDrawableBitmaps`) differ only in fields WordCraft's model lacks (`region`, `bottom_up`); the
  assertions are the same, so the existing Swift tests stand for both. The DIB ones now run through `decodeClip`, and
  the two placement tests run under both crop rules.

Receipts: `swift test --filter CNMetafileTests` passes all of them. `Tools/oracle/oracle.sh metafile-vectors`
(deckcraft at the pin `a3fbf029`) regenerated into a scratch folder is byte-identical to the stored fixtures, and
`metafileOracleParity` matches all 325 cases.

