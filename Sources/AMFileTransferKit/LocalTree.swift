import Foundation

/// A file or folder on the Mac that's about to be copied to the phone.
public struct LocalEntry: Equatable, Sendable {
    public let url: URL
    /// Path below the chosen item. Empty for the chosen item itself.
    public let relativePath: [String]
    public let isFolder: Bool
    public let size: UInt64
}

public enum LocalTree {
    /// Files macOS adds to folders that shouldn't be copied to the phone.
    static let skippedNames: Set<String> = [".DS_Store", ".localized"]

    /// The item at `root` and, for a folder, everything inside it. Folders come before their contents.
    public static func entries(at root: URL) throws -> [LocalEntry] {
        var entries: [LocalEntry] = []
        try walk(root.resolvingSymlinksInPath(), relativePath: [], into: &entries)
        return entries
    }

    static func isSkipped(_ name: String) -> Bool {
        skippedNames.contains(name) || name.hasPrefix("._")
    }

    private static func walk(_ url: URL, relativePath: [String], into entries: inout [LocalEntry]) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        // Links inside folders are skipped, so a link can't make the copy loop forever.
        if values.isSymbolicLink == true { return }
        if values.isDirectory == true {
            entries.append(LocalEntry(url: url, relativePath: relativePath, isFolder: true, size: 0))
            let children = try FileManager.default
                .contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
                .filter { !isSkipped($0.lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try walk(child, relativePath: relativePath + [child.lastPathComponent], into: &entries)
            }
        } else {
            let size = UInt64(max(0, values.fileSize ?? 0))
            entries.append(LocalEntry(url: url, relativePath: relativePath, isFolder: false, size: size))
        }
    }
}
