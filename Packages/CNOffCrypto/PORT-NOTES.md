# CNOffCrypto — notes

> Moved from DeckCraftNative (`Packages/DCOffCrypto`, module `DCOffCrypto`) at `5991914` on 2026-11-01. Tool paths below (`Tools/oracle/…`, `Tools/legacy/…`) are DeckCraftNative's.

Opening and saving password-protected OOXML, from [MS-OFFCRYPTO] v20260217 (in `../OfficeFileFormatsProtocols`), and
the password to modify of a presentation (ECMA-376's `p:modifyVerifier`). **Not a port**: deckcraft has neither. It
depends on CNCFB, the compound file a protected `.pptx` is wrapped in, and uses CommonCrypto for AES, SHA-1 and SHA-2,
HMAC and random bytes. Plan: `Docs/plans/Legacy-PPT-and-Encryption.md` (E2 reads, E3 writes).

## What it reads

- **Agile encryption** (version 4.4; Office 2010 and later). `keyData` and the password key encryptor come from the
  XML, by local name, because writers use different namespace prefixes. The rest:
  - The password is hashed with the salt and iterated `spinCount` times (at most 10,000,000, the specification's
    cap).
  - Three keys come from three fixed block keys: the verifier input, the verifier hash, and the key.
  - The intermediate key decrypts the package in 4096-byte segments. Each segment's IV is the hash of the salt and
    the segment's number.
  - Cipher AES-128, -192 or -256 in CBC mode; hash SHA-1, -256, -384 or -512.
- **The integrity check:** Agile's HMAC covers the whole `EncryptedPackage` stream, size field included. It's
  checked before anything is decrypted, so a changed byte is reported as damage rather than surfacing later as a
  bad zip. The HMAC key is the decrypted `encryptedHmacKey` cut to the hash's size, which is what Office writes
  (the specification's wording says the salt's size).
- **Standard encryption** (versions 2.2, 3.2 and 4.2; Office 2007):
  - SHA-1 iterated 50,000 times, then CryptDeriveKey's 0x36 and 0x5C pads.
  - AES in ECB mode, with no integrity check.
- **Refused by name:** Extensible encryption (x.3), rights-managed files (`\x09DRMContent`, or a DRM transform under
  `\x06DataSpaces`), certificate-only Agile files, and other ciphers and chaining modes.

## What it writes (E3, `OfficeCrypto.encrypt`)

- **As PowerPoint 16 does:** Agile encryption, AES-256 in CBC mode, SHA-512, 100,000 rounds, the HMAC integrity
  check, in a version 4 compound file. The XML matches PowerPoint's shape, including its CRLF after the declaration.
- **Fresh secrets every save:** each salt, the package key, the HMAC key and the verifier are new random bytes from
  `CCRandomGenerateBytes`.
- **The `\x06DataSpaces` storage:**
  - Version, DataSpaceMap, StrongEncryptionDataSpace and `\x06Primary` are built from [MS-OFFCRYPTO] 2.1.4–2.1.9
    and 2.3.4.1–2.3.4.3, and are byte for byte what Apache POI writes.
  - `\x06Primary` ends with an EncryptionTransformInfo whose name is the null string (as the specification asks for
    Agile) and whose block size is 0. The specification says 16 there, but PowerPoint 16 and POI both write 0, and
    for Agile the EncryptionInfo stream is the authority.
- **Checked:**
  - `Tools/legacy/check-encrypt.sh` has msoffcrypto-tool and POI decrypt what we write from every corpus deck, with
    each kind of password. Both get exactly the zip that went in.
  - The tests round-trip every segment boundary.

## The password to modify (`ModifyVerifier`)

- **What it is:** a salted, iterated hash in `ppt/presentation.xml`, not encryption.
  - The hash is H0 = H(salt + password), then H(previous + counter) for each round, with the counter **appended**:
    the reverse of the password-to-open order.
  - The order was settled against PowerPoint 16's own files: only the appended form matches them.
  - PowerPoint writes SHA-512 (`cryptAlgorithmSid="14"`) with 100,000 rounds, and puts the element just before
    `<p:extLst>`.
- **What's read:** SHA-1, SHA-256 and SHA-384 too, and the `algorithmName`, `hashValue` and `saltValue` attribute
  names.
- **On save:** the engine (`Protection.setVerifier`) writes a fresh verifier into the package, with every other part
  kept in order.

## Never crashing, never leaking

- **Bounded input:** sizes, counts, salts and the spin count are bounded before use, and every read past the end
  of a field gives zeros rather than trapping.
- **Cancellable:** the key derivation polls `isCancelled` every 16,384 rounds.
- **Errors carry no secrets:** an error says what failed. It never includes the password, a key or plaintext.

## Checked against

- **The legacy fixtures:** every encrypted `.pptx`, 36 in all, decrypts to the exact bytes it was made from. They
  cover Apache POI's Agile AES-256/SHA-512 and AES-128/SHA-1 and its Standard AES-128, and msoffcrypto-tool's
  Agile. The passwords are ASCII, accented, outside the BMP, and 255 characters long.
- **PowerPoint 16's own files:** its 9 protected copies (local only) decrypt to the same bytes msoffcrypto-tool
  gets. PowerPoint writes Agile AES-256/SHA-512 with 100,000 rounds.
- **Failure cases:** a wrong password, or the right one in the wrong case, is `wrongPassword`; a flipped byte in
  the package fails the HMAC; cancelling stops the derivation; the hostile fixtures and 300 seeded corruptions end
  in an error.

## In the engine and the app (E2–E3)

- **The engine:** `FileCommands.openProtected(name, bytes, password:)` reads a protected file. The commands:
  - `file.open` and `file.openBytes` take `password`.
  - Without a password the error is `EngineError.passwordRequired`; with a wrong one, `wrongPassword`.
  - The password is kept with the open document (`DocState.protection`) and nowhere else: not in the
    presentation, not in the journal (the engine drops a `password` parameter before journaling), not in
    AutoRecover, and not in a reply.
- **Saving (E3):** `Protection.fileBytes` writes a protected presentation as `.pptx`, `.potx` or `.ppsx` with its
  password to modify (a verifier) and encrypted with its password to open.
  - Saved as `.deckcraft` or an outline, it has no passwords afterwards, and the status line says so.
  - AutoRecover leaves a protected presentation out, so nothing is ever written in the clear.
  - Exports (PDF, pictures, and `file.export` to `.pptx`) are copies and aren't protected.
- **Opening with a password to modify:** without the password the file opens read-only, as an untitled copy titled
  "(Read-Only)", so Save asks where. `file.open {modifyPassword}` opens it for editing, and a wrong one is
  `wrongPassword`.
- **Setting passwords:** File › Passwords… and Review › Protect Presentation (`file.passwords`, an app command) open
  a sheet like PowerPoint's: one checkbox per password, each typed twice. With parameters
  (`{password?, modifyPassword?}`, null to remove), scripts set them directly. A change makes the document need
  saving (`DocState.protectionEdited`).
- **The journal** drops every parameter whose name contains "password".
- **The app:** `PasswordPrompt` asks the way PowerPoint's *Password to Open* does, before the document's window,
  and asks again after a wrong password. The control channel's `app.open {path, password}` never prompts: a
  missing or wrong password comes back as an error.
- **dccli:** reads the password of a protected input from `DCCLI_PASSWORD`, keeping it out of the command line.
