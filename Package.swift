// swift-tools-version: 6.2
// CraftNativeKit — the base packages the native craft ports share (macOS 26+, Apple Silicon): Rust semantics and
// serde-exact JSON, ZIP, the Compound File Binary format, password-protected Office files, and EMF/WMF. They were
// written for DeckCraftNative (xocialize/DeckCraftNative) and moved here on 2026-11-01 so Marquee Documents
// (Mountain-View-Staging/MarqueeDocuments) builds on the same code. Both depend on this repo by URL.
//
// Targets keep their sources at `Packages/<package>/{Sources,Tests}/<target>`. Nothing here imports AppKit or
// SwiftUI. Ports deckcraft and photocraft (MIT OR Apache-2.0, © ArtCraft Team and their contributors); every ported
// file names its source and licence. Test data stays outside git, at `CRAFTNATIVEKIT_FIXTURES` (default
// `../DeckCraftNative-Fixtures`, where DeckCraftNative's oracle writes it); tests that need it skip or say so.
import PackageDescription

/// `Packages/<package>/Sources/<target>`.
func sources(_ package: String, _ target: String) -> String { "Packages/\(package)/Sources/\(target)" }
/// `Packages/<package>/Tests/<target>`.
func tests(_ package: String, _ target: String) -> String { "Packages/\(package)/Tests/\(target)" }

let package = Package(
    name: "CraftNativeKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CNCore", targets: ["CNCore"]),
        .library(name: "CNZip", targets: ["CNZip"]),
        .library(name: "CNCFB", targets: ["CNCFB"]),
        .library(name: "CNOffCrypto", targets: ["CNOffCrypto"]),
        .library(name: "CNMetafile", targets: ["CNMetafile"]),
    ],
    targets: [
        // MARK: CNCore — serde_json-compatible JSON (value, writer, parser, serde-style coding) and Rust's numeric and
        // string semantics (saturating casts, NaN-propagating clamp, `chars()` counts). Every port builds on it.
        .target(name: "CNCore", path: sources("CNCore", "CNCore")),
        .testTarget(name: "CNCoreTests", dependencies: ["CNCore", "CNTestSupport"], path: tests("CNCore", "CNCoreTests")),

        // MARK: CNZip — ZIP (ZIP64 included) and raw DEFLATE through Apple's Compression framework, from
        // PhotoCraftNative.
        .target(name: "CNZip", path: sources("CNZip", "CNZip")),
        .testTarget(name: "CNZipTests", dependencies: ["CNZip"], path: tests("CNZip", "CNZipTests")),

        // MARK: CNCFB — the Compound File Binary format ([MS-CFB]), read and written: the container of password-
        // protected OOXML, legacy .ppt and legacy .doc. No dependencies.
        .target(name: "CNCFB", path: sources("CNCFB", "CNCFB")),
        .testTarget(name: "CNCFBTests", dependencies: ["CNCFB", "CNTestSupport"], path: tests("CNCFB", "CNCFBTests")),

        // MARK: CNOffCrypto — password-protected OOXML ([MS-OFFCRYPTO]): Agile and Standard encryption, read and
        // written through CommonCrypto.
        .target(name: "CNOffCrypto", dependencies: ["CNCFB"], path: sources("CNOffCrypto", "CNOffCrypto")),
        .testTarget(name: "CNOffCryptoTests", dependencies: ["CNOffCrypto", "CNCFB", "CNTestSupport"], path: tests("CNOffCrypto", "CNOffCryptoTests")),

        // MARK: CNMetafile — EMF, EMF+ and WMF read into a neutral vector model (deckcraft-metafile, itself ported
        // from WordCraft's).
        .target(name: "CNMetafile", dependencies: ["CNCore"], path: sources("CNMetafile", "CNMetafile")),
        .testTarget(name: "CNMetafileTests", dependencies: ["CNMetafile", "CNCore", "CNTestSupport"], path: tests("CNMetafile", "CNMetafileTests")),

        // MARK: CNTestSupport — where the tests find their fixtures. Not a product.
        .target(name: "CNTestSupport", path: sources("CNTestSupport", "CNTestSupport")),
    ]
)
