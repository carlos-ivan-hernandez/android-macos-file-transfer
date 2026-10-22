import Foundation

/// A file or folder on the phone.
public struct PhoneItem: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let storageID: UInt32
    public let parentID: UInt32
    public let name: String
    public let size: UInt64
    public let modified: Date?
    public let isFolder: Bool

    public init(
        id: UInt32, storageID: UInt32, parentID: UInt32, name: String,
        size: UInt64, modified: Date?, isFolder: Bool
    ) {
        self.id = id
        self.storageID = storageID
        self.parentID = parentID
        self.name = name
        self.size = size
        self.modified = modified
        self.isFolder = isFolder
    }

    /// For sorting: items without a date go first.
    public var sortDate: Date { modified ?? .distantPast }
}

/// A storage area on the phone, such as "Internal storage" or an SD card.
public struct PhoneStorage: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public let freeBytes: UInt64
    public let capacityBytes: UInt64

    public init(id: UInt32, name: String, freeBytes: UInt64, capacityBytes: UInt64) {
        self.id = id
        self.name = name
        self.freeBytes = freeBytes
        self.capacityBytes = capacityBytes
    }
}

public enum PhoneFolder {
    /// The folder ID for the top of a storage. libmtp treats 0 as "pick a default folder"
    /// (for example DCIM for photos), so the root is always passed explicitly.
    public static let root: UInt32 = 0xFFFF_FFFF
}

public enum PhoneError: Error, LocalizedError, Equatable {
    /// No Android phone is plugged in.
    case noPhone
    /// A phone is plugged in, but another app (often macOS's own photo import service) is using it.
    case busy
    /// The phone is connected but shows no storage: it's locked, or access hasn't been allowed yet.
    case locked
    /// The connection was closed.
    case closed
    case failed(String, details: String)

    public var errorDescription: String? {
        switch self {
        case .noPhone: return "No Android phone is connected."
        case .busy: return "The phone is connected, but another app is using it."
        case .locked: return "Unlock your phone and allow access to its data."
        case .closed: return "The phone was disconnected."
        case .failed(let message, _): return message
        }
    }

    public var details: String? {
        if case .failed(_, let details) = self, !details.isEmpty { return details }
        return nil
    }
}

/// What AM File Transfer needs from a connected phone. `MTPConnection` is the real one; the tests use a fake.
public protocol PhoneDevice: AnyObject, Sendable {
    func list(storage: UInt32, folder: UInt32) async throws -> [PhoneItem]
    /// Copies a phone file to `url`. `progress` gets the bytes copied so far and returns false to cancel.
    func download(_ item: PhoneItem, to url: URL, progress: @escaping @Sendable (UInt64) -> Bool) async throws
    /// Copies a Mac file into a phone folder and returns the new item.
    func upload(
        _ url: URL, name: String, size: UInt64, storage: UInt32, folder: UInt32,
        progress: @escaping @Sendable (UInt64) -> Bool
    ) async throws -> PhoneItem
    func createFolder(named name: String, storage: UInt32, in folder: UInt32) async throws -> PhoneItem
    func delete(_ item: PhoneItem) async throws
}
