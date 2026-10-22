import CLibMTP
import Foundation

/// A USB connection to an Android phone, through libmtp.
///
/// libmtp isn't thread-safe, so every call goes through one serial queue. Transfers block that
/// queue, so other calls wait until the current transfer is done.
public final class MTPConnection: PhoneDevice, @unchecked Sendable {
    public struct Info: Sendable {
        public let name: String
        public let manufacturer: String?
        public let model: String?
        /// USB IDs, for noticing when the phone is unplugged.
        public let vendorID: UInt16
        public let productID: UInt16
    }

    private static let queue = DispatchQueue(label: "AMFileTransfer.libmtp")
    private static let initialize: Void = LIBMTP_Init()

    /// Only touched on `queue`.
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    public let info: Info

    private init(device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, info: Info) {
        self.device = device
        self.info = info
    }

    // MARK: Connecting

    /// Whether an MTP device (an Android phone set to "File transfer") is plugged in.
    public static func phoneAttached() async -> Bool {
        (try? await run { try withRawDevices { _, count in count > 0 } }) ?? false
    }

    /// Opens the first phone that can be opened.
    public static func connect() async throws -> MTPConnection {
        try await run {
            try withRawDevices { raws, count in
                for index in 0..<count {
                    if let device = LIBMTP_Open_Raw_Device_Uncached(raws + index) {
                        return MTPConnection(device: device, info: readInfo(device, raw: raws[index]))
                    }
                }
                throw PhoneError.busy
            }
        }
    }

    /// Lets go of the phone. Waits for a running transfer to finish or be cancelled.
    public func close() async {
        _ = try? await Self.run { [self] in
            if let device {
                LIBMTP_Release_Device(device)
                self.device = nil
            }
        }
    }

    // MARK: Browsing

    public func storages() async throws -> [PhoneStorage] {
        try await Self.run { [self] in
            let device = try openDevice()
            let result = LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED)
            var storages: [PhoneStorage] = []
            var next = device.pointee.storage
            while let storage = next {
                let s = storage.pointee
                storages.append(PhoneStorage(
                    id: s.id,
                    name: Self.string(s.StorageDescription) ?? "Storage",
                    freeBytes: s.FreeSpaceInBytes,
                    capacityBytes: s.MaxCapacity
                ))
                next = s.next
            }
            LIBMTP_Clear_Errorstack(device)
            // A locked phone, or one where "Allow access to phone data" hasn't been tapped, reports no storage.
            guard result == 0, !storages.isEmpty else { throw PhoneError.locked }
            return storages
        }
    }

    public func list(storage: UInt32, folder: UInt32) async throws -> [PhoneItem] {
        try await Self.run { [self] in
            let device = try openDevice()
            LIBMTP_Clear_Errorstack(device)
            var items: [PhoneItem] = []
            var next = LIBMTP_Get_Files_And_Folders(device, storage, folder)
            if next == nil, LIBMTP_Get_Errorstack(device) != nil {
                throw failure(device, "Couldn't read the folder on the phone.")
            }
            while let file = next {
                let f = file.pointee
                items.append(PhoneItem(
                    id: f.item_id,
                    storageID: f.storage_id,
                    parentID: f.parent_id,
                    name: Self.string(f.filename) ?? "Untitled",
                    size: f.filesize,
                    modified: f.modificationdate > 0
                        ? Date(timeIntervalSince1970: TimeInterval(f.modificationdate)) : nil,
                    isFolder: f.filetype == LIBMTP_FILETYPE_FOLDER
                ))
                next = f.next
                LIBMTP_destroy_file_t(file)
            }
            return items
        }
    }

    // MARK: Changing files

    public func download(
        _ item: PhoneItem, to url: URL, progress: @escaping @Sendable (UInt64) -> Bool
    ) async throws {
        try await Self.run { [self] in
            let device = try openDevice()
            let box = ProgressBox(progress)
            let context = Unmanaged.passRetained(box)
            defer { context.release() }
            let result = url.withUnsafeFileSystemRepresentation { path in
                LIBMTP_Get_File_To_File(device, item.id, path, progressCallback, context.toOpaque())
            }
            if box.cancelled {
                LIBMTP_Clear_Errorstack(device)
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
            if result != 0 {
                try? FileManager.default.removeItem(at: url)
                throw failure(device, "Couldn't copy “\(item.name)” from the phone.")
            }
        }
    }

    public func upload(
        _ url: URL, name: String, size: UInt64, storage: UInt32, folder: UInt32,
        progress: @escaping @Sendable (UInt64) -> Bool
    ) async throws -> PhoneItem {
        try await Self.run { [self] in
            let device = try openDevice()
            guard let metadata = LIBMTP_new_file_t() else {
                throw PhoneError.failed("Out of memory.", details: "")
            }
            defer { LIBMTP_destroy_file_t(metadata) }  // also frees `filename`
            metadata.pointee.filename = strdup(name)
            metadata.pointee.filesize = size
            metadata.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
            metadata.pointee.parent_id = folder
            metadata.pointee.storage_id = storage

            let box = ProgressBox(progress)
            let context = Unmanaged.passRetained(box)
            defer { context.release() }
            let result = url.withUnsafeFileSystemRepresentation { path in
                LIBMTP_Send_File_From_File(device, path, metadata, progressCallback, context.toOpaque())
            }
            let newID = metadata.pointee.item_id
            if box.cancelled || result != 0 {
                // Don't leave a half-copied file on the phone.
                if newID != 0 { LIBMTP_Delete_Object(device, newID) }
                if box.cancelled {
                    LIBMTP_Clear_Errorstack(device)
                    throw CancellationError()
                }
                throw failure(device, "Couldn't copy “\(name)” to the phone.")
            }
            return PhoneItem(
                id: newID, storageID: storage, parentID: folder,
                name: Self.string(metadata.pointee.filename) ?? name,
                size: size, modified: Date(), isFolder: false
            )
        }
    }

    public func createFolder(named name: String, storage: UInt32, in folder: UInt32) async throws -> PhoneItem {
        try await Self.run { [self] in
            let device = try openDevice()
            // libmtp may change the name it's given, so it gets its own copy.
            guard let cName = strdup(name) else { throw PhoneError.failed("Out of memory.", details: "") }
            defer { free(cName) }
            let newID = LIBMTP_Create_Folder(device, cName, folder, storage)
            guard newID != 0 else { throw failure(device, "Couldn't create the folder “\(name)”.") }
            return PhoneItem(
                id: newID, storageID: storage, parentID: folder, name: String(cString: cName),
                size: 0, modified: Date(), isFolder: true
            )
        }
    }

    public func delete(_ item: PhoneItem) async throws {
        try await Self.run { [self] in
            let device = try openDevice()
            guard LIBMTP_Delete_Object(device, item.id) == 0 else {
                throw failure(device, "Couldn't delete “\(item.name)”.")
            }
        }
    }

    // MARK: Helpers

    /// Runs libmtp work on the libmtp queue.
    private static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                _ = initialize
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func withRawDevices<T>(
        _ body: (UnsafeMutablePointer<LIBMTP_raw_device_t>, Int) throws -> T
    ) throws -> T {
        var raws: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let result = LIBMTP_Detect_Raw_Devices(&raws, &count)
        defer { free(raws) }
        if result == LIBMTP_ERROR_NO_DEVICE_ATTACHED { throw PhoneError.noPhone }
        guard result == LIBMTP_ERROR_NONE else {
            throw PhoneError.failed("Couldn't look for USB devices.", details: "libmtp error \(result.rawValue)")
        }
        guard let raws, count > 0 else { throw PhoneError.noPhone }
        return try body(raws, Int(count))
    }

    private static func readInfo(
        _ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, raw: LIBMTP_raw_device_t
    ) -> Info {
        let friendly = takeString(LIBMTP_Get_Friendlyname(device))
        let manufacturer = takeString(LIBMTP_Get_Manufacturername(device))
        let model = takeString(LIBMTP_Get_Modelname(device))
        LIBMTP_Clear_Errorstack(device)
        let fallback = [manufacturer, model].compactMap { $0 }.joined(separator: " ")
        let name = friendly ?? (fallback.isEmpty ? string(raw.device_entry.vendor) ?? "Android Phone" : fallback)
        return Info(
            name: name, manufacturer: manufacturer, model: model,
            vendorID: raw.device_entry.vendor_id, productID: raw.device_entry.product_id
        )
    }

    private func openDevice() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let device else { throw PhoneError.closed }
        return device
    }

    /// Turns libmtp's error stack into a `PhoneError`, then clears it.
    private func failure(_ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, _ message: String) -> PhoneError {
        var lines: [String] = []
        var next = LIBMTP_Get_Errorstack(device)
        while let error = next {
            if let text = Self.string(error.pointee.error_text) { lines.append(text) }
            next = error.pointee.next
        }
        LIBMTP_Clear_Errorstack(device)
        return .failed(message, details: lines.joined(separator: "\n"))
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        string(pointer.map { UnsafePointer($0) })
    }

    /// Reads a string libmtp allocated for us, then frees it.
    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        defer { free(pointer) }
        return string(pointer)
    }
}

/// Passes a Swift progress closure through libmtp's C callback.
private final class ProgressBox {
    let report: (UInt64) -> Bool
    var cancelled = false
    init(_ report: @escaping (UInt64) -> Bool) { self.report = report }
}

private let progressCallback: LIBMTP_progressfunc_t = { sent, _, context in
    guard let context else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    if box.report(sent) { return 0 }
    box.cancelled = true
    return 1  // non-zero tells libmtp to stop
}
