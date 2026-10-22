import Foundation

/// The total size of some files and folders.
public struct SizeSummary: Equatable, Sendable {
    public var bytes: UInt64 = 0
    public var files = 0

    public init(bytes: UInt64 = 0, files: Int = 0) {
        self.bytes = bytes
        self.files = files
    }

    public static func + (a: SizeSummary, b: SizeSummary) -> SizeSummary {
        SizeSummary(bytes: a.bytes + b.bytes, files: a.files + b.files)
    }

    public static func += (a: inout SizeSummary, b: SizeSummary) { a = a + b }
}

public enum SizeCounter {
    /// Adds up a phone folder's files, including those in folders inside it.
    /// Stops with `CancellationError` when the task is cancelled.
    public static func measure(_ folder: PhoneItem, on device: any PhoneDevice) async throws -> SizeSummary {
        try Task.checkCancellation()
        var total = SizeSummary()
        for child in try await device.list(storage: folder.storageID, folder: folder.id) {
            if child.isFolder {
                total += try await measure(child, on: device)
            } else {
                total += SizeSummary(bytes: child.size, files: 1)
            }
        }
        return total
    }
}
