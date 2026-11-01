# CraftNativeKit — working notes

Shared base packages for DeckCraftNative and Marquee Documents. [README.md](README.md) says what each one is.

- **History.** Moved out of DeckCraftNative at `5991914` (2026-11-01). Each package's `PORT-NOTES.md` keeps its
  history from there; DeckCraftNative's `PORT-STATUS.md` keeps the measurements up to the move.
- **Never crash.** As in the ports: no `!`, `try!`, `fatalError`, `precondition`, `as!`, or unchecked subscripts on
  input-derived indices in production targets.
- **Every change reaches two apps.** Run `swift test` here, tag a new version, then move each consumer's dependency
  and run its tests. Never tag over an existing version.
- **Fixtures** come from DeckCraftNative's oracle tools (`Tools/oracle/oracle.sh json-vectors`, `display-vectors`,
  `metafile-vectors`, and `Tools/legacy/make-fixtures.sh`). The scripts that hand files from these tests to other
  readers (`check-cfb-writer.sh`, `check-encrypt.sh`) live there too and run `swift test` in this repo.
- **serde2swift.py** writes `import CNCore`. A consumer's `Tools/port/generate.sh` runs it from this checkout
  (`../CraftNativeKit`) or from `.build/checkouts/CraftNativeKit`.
