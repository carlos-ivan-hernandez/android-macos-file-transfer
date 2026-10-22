import Foundation

public struct TransferProgress: Equatable, Sendable {
    public var title: String
    public var fileName: String
    public var fileNumber: Int
    public var fileCount: Int
    public var bytesDone: UInt64
    public var bytesTotal: UInt64

    public init(
        title: String, fileName: String = "", fileNumber: Int = 0, fileCount: Int = 0,
        bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0
    ) {
        self.title = title
        self.fileName = fileName
        self.fileNumber = fileNumber
        self.fileCount = fileCount
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    /// 0…1. Uses bytes when there are any, otherwise the number of files.
    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if fileCount > 0 { return min(1, Double(max(0, fileNumber - 1)) / Double(fileCount)) }
        return 0
    }
}

public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Copies and deletes files and whole folders, reporting progress as it goes.
public struct Transfers: Sendable {
    public let device: any PhoneDevice
    public let cancel: CancelFlag
    private let throttle: Throttle

    /// `report` is called often during a transfer (at most about 20 times a second while bytes move).
    public init(device: any PhoneDevice, cancel: CancelFlag, report: @escaping @Sendable (TransferProgress) -> Void) {
        self.device = device
        self.cancel = cancel
        self.throttle = Throttle(report)
    }

    // MARK: Phone → Mac

    /// Copies phone files and folders into a Mac folder. Names already in use get a number,
    /// like "photo 2.jpg". Returns the copied top-level items.
    @discardableResult
    public func copyToMac(_ items: [PhoneItem], into folder: URL) async throws -> [URL] {
        let fileManager = FileManager.default
        var plan = DownloadPlan()
        var claimed = Set<String>()
        var topLevel: [URL] = []
        for item in items {
            let name = UniqueName.make(for: UniqueName.safeFileName(item.name), isFolder: item.isFolder) {
                claimed.contains($0.lowercased())
                    || fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            claimed.insert(name.lowercased())
            let destination = folder.appendingPathComponent(name, isDirectory: item.isFolder)
            topLevel.append(destination)
            if item.isFolder {
                try await planFolder(item, at: destination, into: &plan)
            } else {
                plan.files.append((item, destination))
            }
        }

        for directory in plan.folders {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let total = plan.files.reduce(UInt64(0)) { $0 + $1.item.size }
        var done: UInt64 = 0
        for (index, file) in plan.files.enumerated() {
            try checkCancelled()
            let base = TransferProgress(
                title: "Copying to Mac", fileName: file.item.name, fileNumber: index + 1,
                fileCount: plan.files.count, bytesDone: done, bytesTotal: total
            )
            throttle.send(base, force: true)
            let throttle = self.throttle, cancel = self.cancel, start = done
            try await device.download(file.item, to: file.destination) { sent in
                var progress = base
                progress.bytesDone = start + sent
                throttle.send(progress)
                return !cancel.isCancelled
            }
            done += file.item.size
        }
        return topLevel
    }

    private struct DownloadPlan {
        var folders: [URL] = []
        var files: [(item: PhoneItem, destination: URL)] = []
    }

    private func planFolder(_ folder: PhoneItem, at destination: URL, into plan: inout DownloadPlan) async throws {
        try checkCancelled()
        throttle.send(TransferProgress(title: "Preparing…", fileName: folder.name), force: true)
        plan.folders.append(destination)
        for child in try await device.list(storage: folder.storageID, folder: folder.id) {
            let childURL = destination.appendingPathComponent(
                UniqueName.safeFileName(child.name), isDirectory: child.isFolder
            )
            if child.isFolder {
                try await planFolder(child, at: childURL, into: &plan)
            } else {
                plan.files.append((child, childURL))
            }
        }
    }

    // MARK: Mac → Phone

    /// Copies Mac files and folders into a phone folder. Names already in use get a number.
    public func copyToPhone(_ urls: [URL], storage: UInt32, folder: UInt32) async throws {
        throttle.send(TransferProgress(title: "Preparing…"), force: true)
        let existing = try await device.list(storage: storage, folder: folder)
        var taken = Set(existing.map { $0.name.lowercased() })
        var plans: [(name: String, entries: [LocalEntry])] = []
        for url in urls {
            try checkCancelled()
            let entries = try LocalTree.entries(at: url)
            guard let top = entries.first else { continue }
            let name = UniqueName.make(for: top.url.lastPathComponent, isFolder: top.isFolder) {
                taken.contains($0.lowercased())
            }
            taken.insert(name.lowercased())
            plans.append((name, entries))
        }

        let files = plans.flatMap { $0.entries }.filter { !$0.isFolder }
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        var done: UInt64 = 0
        var fileNumber = 0
        for plan in plans {
            // Phone folder IDs by path, "" being the destination folder.
            var folderIDs: [String: UInt32] = ["": folder]
            for entry in plan.entries {
                try checkCancelled()
                let path = [plan.name] + entry.relativePath
                guard let parentID = folderIDs[path.dropLast().joined(separator: "/")] else { continue }
                let name = path[path.count - 1]
                if entry.isFolder {
                    let created = try await device.createFolder(named: name, storage: storage, in: parentID)
                    folderIDs[path.joined(separator: "/")] = created.id
                    continue
                }
                fileNumber += 1
                let base = TransferProgress(
                    title: "Copying to Phone", fileName: name, fileNumber: fileNumber,
                    fileCount: files.count, bytesDone: done, bytesTotal: total
                )
                throttle.send(base, force: true)
                let throttle = self.throttle, cancel = self.cancel, start = done
                _ = try await device.upload(
                    entry.url, name: name, size: entry.size, storage: storage, folder: parentID
                ) { sent in
                    var progress = base
                    progress.bytesDone = start + sent
                    throttle.send(progress)
                    return !cancel.isCancelled
                }
                done += entry.size
            }
        }
    }

    // MARK: Delete

    /// Deletes phone files and folders. A folder's contents are deleted first.
    public func delete(_ items: [PhoneItem]) async throws {
        var order: [PhoneItem] = []
        for item in items { try await planDelete(item, into: &order) }
        for (index, item) in order.enumerated() {
            try checkCancelled()
            throttle.send(
                TransferProgress(title: "Deleting", fileName: item.name, fileNumber: index + 1, fileCount: order.count),
                force: true
            )
            try await device.delete(item)
        }
    }

    private func planDelete(_ item: PhoneItem, into order: inout [PhoneItem]) async throws {
        try checkCancelled()
        if item.isFolder {
            throttle.send(TransferProgress(title: "Preparing…", fileName: item.name), force: true)
            for child in try await device.list(storage: item.storageID, folder: item.id) {
                try await planDelete(child, into: &order)
            }
        }
        order.append(item)
    }

    private func checkCancelled() throws {
        if cancel.isCancelled { throw CancellationError() }
    }
}

/// Limits how often byte progress is reported.
private final class Throttle: @unchecked Sendable {
    private let report: @Sendable (TransferProgress) -> Void
    private let lock = NSLock()
    private var last = Date.distantPast

    init(_ report: @escaping @Sendable (TransferProgress) -> Void) { self.report = report }

    func send(_ progress: TransferProgress, force: Bool = false) {
        lock.lock()
        let now = Date()
        let due = force || now.timeIntervalSince(last) >= 0.05
        if due { last = now }
        lock.unlock()
        if due { report(progress) }
    }
}
