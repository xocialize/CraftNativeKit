# CNCFB — notes

> Moved from DeckCraftNative (`Packages/DCCFB`, module `DCCFB`) at `5991914` on 2026-11-01. Tool paths below (`Tools/oracle/…`, `Tools/legacy/…`) are DeckCraftNative's.

The Compound File Binary format, read and written, from [MS-CFB] v20210625 (in `../OfficeFileFormatsProtocols`; the
2024 edition on Microsoft's site is a rights-protected PDF). **Not a port**: deckcraft has only an encryption
sniffer, which DCPPTX keeps as deckcraft wrote it (`CFB.swift`), because 400 parity vectors pin its behaviour,
including its fallback scan for stream names in files it can't walk. CNCFB serves the legacy wave
(`Docs/plans/Legacy-PPT-and-Encryption.md`): the container of password-protected OOXML and of `.ppt`. It has no
dependencies.

## Reading (`CompoundFile`)

- **Versions:** 3 (512-byte sectors) and 4 (4096-byte sectors). Anything else is `unsupported`.
- **What it follows:** the DIFAT (the header's 109 entries, then chained DIFAT sectors), the FAT, the directory, the
  mini FAT and the mini stream (the root entry's stream; 64-byte sectors for streams under 4096 bytes).
- **The directory:** each storage's red-black tree is walked in order through its left, right and child links;
  colours are ignored. Entries reachable from the root are listed root first, then storage by storage, breadth
  first. Unreachable entries (deleted streams, free slots) aren't listed.
- **Names** compare as the format orders them (`CFBName`): case-insensitively, by upper-casing each UTF-16 unit.
- **Version 3 stream sizes:** the high 32 bits are ignored, as [MS-CFB] 2.6.3 asks, because old writers left junk
  there.
- **A last sector cut short** by its writer reads as if padded with zeros.

### Never crashing

Every sector id is range-checked, and each chain records the sectors it has visited, so a loop is an error
(`malformed`) and never a hang. A stream can't claim more bytes than the file's sectors hold, so a hostile size
never drives an allocation. The tree walk is iterative and visits each entry once; a second link to the same entry
is an error. The tests feed it the hostile fixtures, deckcraft's 400 CFB parity inputs (many malformed), and 6,000
seeded mutations of written files, version 3 and 4.

## Writing (`CompoundFileWriter`)

- **Versions:** 3 by default, or 4. Apache POI and msoffcrypto-tool write protected `.pptx` as version 3;
  PowerPoint 16 writes version 4.
- **Layout, fixed for given input:** the mini stream, the large streams in directory order, the directory, the mini
  FAT, the FAT, and the DIFAT when there are over 109 FAT sectors.
- **The trees:** each storage's children form a balanced binary tree in the format's name order, every node black.
  [MS-CFB] 2.6.4 calls marking every node black "the simplest implementation".
- **Names:** at most 31 UTF-16 units, with no `\`, `:` or `!`. Duplicates are refused, case-insensitively.
- **Not written:** timestamps (left zero) and state bits.

## Checked against

- **olefile:** every compound file in the legacy fixtures (105) and PowerPoint's own protected copies (15, local
  only) reads with the same storages and streams and the same bytes. The references are `reference/*.olefile.json`
  from `Tools/legacy/fixtures.py olefile-list`.
- **olefile and Apache POI:** `Tools/legacy/check-cfb-writer.sh` has CNCFBTests write five files (version 3 and 4,
  mini and large streams, a DIFAT, 300 entries) and has both readers list them. Every storage and stream comes back
  where it was written, with the same bytes.
