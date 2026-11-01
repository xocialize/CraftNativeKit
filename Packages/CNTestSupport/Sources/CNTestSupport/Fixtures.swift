// CNTestSupport — where CraftNativeKit's tests find their fixtures. The vectors (serde_json's floats, Rust's float
// Display, deckcraft-metafile's dumps, the legacy and encrypted files) are written by DeckCraftNative's oracle tools
// (`Tools/oracle/oracle.sh`, `Tools/legacy/make-fixtures.sh` there), so the default is its fixtures folder.
import Foundation

/// The fixtures folder: `CRAFTNATIVEKIT_FIXTURES`, else `DECKCRAFT_FIXTURES`, else `../DeckCraftNative-Fixtures`
/// beside this repository.
public enum Fixtures {
    /// This repository's root, found from this file's path.
    public static var repositoryRoot: URL {
        // …/Packages/CNTestSupport/Sources/CNTestSupport/Fixtures.swift
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    public static var root: URL {
        let env = ProcessInfo.processInfo.environment
        for key in ["CRAFTNATIVEKIT_FIXTURES", "DECKCRAFT_FIXTURES"] {
            if let value = env[key], !value.isEmpty { return URL(filePath: value, directoryHint: .isDirectory) }
        }
        return repositoryRoot.deletingLastPathComponent().appending(path: "DeckCraftNative-Fixtures", directoryHint: .isDirectory)
    }
}
