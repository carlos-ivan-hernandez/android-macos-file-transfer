import Foundation

public enum UniqueName {
    /// Returns `name`, or the first free "name 2.ext", "name 3.ext", … if it's taken, like Finder does.
    public static func make(for name: String, isFolder: Bool, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let (stem, ext) = split(name, isFolder: isFolder)
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// Makes a phone name safe to use as a Mac file name.
    public static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
    }

    static func split(_ name: String, isFolder: Bool) -> (stem: String, ext: String) {
        guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex
        else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
