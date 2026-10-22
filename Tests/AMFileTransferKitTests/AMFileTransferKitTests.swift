import Foundation
@testable import AMFileTransferKit
import XCTest

/// An in-memory phone.
final class FakePhone: PhoneDevice, @unchecked Sendable {
    struct Node {
        var name: String
        var parent: UInt32
        var isFolder: Bool
        var data: Data
    }

    static let storage: UInt32 = 0x10001
    private let lock = NSLock()
    private(set) var nodes: [UInt32: Node] = [:]
    private(set) var deleteOrder: [String] = []
    private var nextID: UInt32 = 1

    @discardableResult
    func add(_ name: String, in parent: UInt32 = PhoneFolder.root, folder: Bool = false, data: String = "") -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        nodes[id] = Node(name: name, parent: parent, isFolder: folder, data: Data(data.utf8))
        return id
    }

    func item(_ id: UInt32) -> PhoneItem {
        let node = nodes[id]!
        return PhoneItem(
            id: id, storageID: Self.storage, parentID: node.parent, name: node.name,
            size: UInt64(node.data.count), modified: nil, isFolder: node.isFolder
        )
    }

    func child(named name: String, in parent: UInt32 = PhoneFolder.root) -> UInt32? {
        nodes.first { $0.value.parent == parent && $0.value.name == name }?.key
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func list(storage: UInt32, folder: UInt32) async throws -> [PhoneItem] {
        locked { nodes.filter { $0.value.parent == folder }.keys.sorted().map { item($0) } }
    }

    func download(_ item: PhoneItem, to url: URL, progress: @escaping @Sendable (UInt64) -> Bool) async throws {
        let data = nodes[item.id]!.data
        try data.write(to: url)
        if !progress(UInt64(data.count)) {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
    }

    func upload(
        _ url: URL, name: String, size: UInt64, storage: UInt32, folder: UInt32,
        progress: @escaping @Sendable (UInt64) -> Bool
    ) async throws -> PhoneItem {
        let data = try Data(contentsOf: url)
        guard progress(UInt64(data.count)) else { throw CancellationError() }
        return item(add(name, in: folder, data: String(decoding: data, as: UTF8.self)))
    }

    func createFolder(named name: String, storage: UInt32, in folder: UInt32) async throws -> PhoneItem {
        item(add(name, in: folder, folder: true))
    }

    func delete(_ item: PhoneItem) async throws {
        try locked { try remove(item) }
    }

    private func remove(_ item: PhoneItem) throws {
        if nodes.values.contains(where: { $0.parent == item.id }) {
            throw PhoneError.failed("Folder isn't empty", details: "")
        }
        deleteOrder.append(item.name)
        nodes[item.id] = nil
    }
}

final class AMFileTransferKitTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("AMFileTransferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func transfers(_ phone: FakePhone, cancel: CancelFlag = CancelFlag()) -> Transfers {
        Transfers(device: phone, cancel: cancel) { _ in }
    }

    private func write(_ text: String, to path: String) throws {
        let url = temp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: temp.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: UniqueName

    func testUniqueNameAddsANumberBeforeTheExtension() {
        let taken: Set<String> = ["photo.jpg", "photo 2.jpg", "Notes", ".hidden"]
        XCTAssertEqual(UniqueName.make(for: "new.jpg", isFolder: false) { taken.contains($0) }, "new.jpg")
        XCTAssertEqual(UniqueName.make(for: "photo.jpg", isFolder: false) { taken.contains($0) }, "photo 3.jpg")
        XCTAssertEqual(UniqueName.make(for: "Notes", isFolder: true) { taken.contains($0) }, "Notes 2")
        XCTAssertEqual(UniqueName.make(for: ".hidden", isFolder: false) { taken.contains($0) }, ".hidden 2")
    }

    func testFolderNamesKeepTheirDots() {
        XCTAssertEqual(UniqueName.make(for: "v1.2", isFolder: true) { $0 == "v1.2" }, "v1.2 2")
    }

    func testSafeFileName() {
        XCTAssertEqual(UniqueName.safeFileName("a/b"), "a-b")
        XCTAssertEqual(UniqueName.safeFileName("  "), "Untitled")
        XCTAssertEqual(UniqueName.safeFileName(".."), "Untitled")
    }

    // MARK: LocalTree

    func testLocalTreeListsFoldersBeforeContentsAndSkipsMacFiles() throws {
        try write("a", to: "Trip/a.txt")
        try write("b", to: "Trip/Day 2/b.txt")
        try write("x", to: "Trip/.DS_Store")
        try write("x", to: "Trip/._a.txt")
        let entries = try LocalTree.entries(at: temp.appendingPathComponent("Trip"))
        XCTAssertEqual(entries.map(\.relativePath), [[], ["Day 2"], ["Day 2", "b.txt"], ["a.txt"]])
        XCTAssertEqual(entries.map(\.isFolder), [true, true, false, false])
        XCTAssertEqual(entries[2].size, 1)
    }

    // MARK: Copying

    func testCopyToMacCopiesFoldersAndRenamesConflicts() async throws {
        let phone = FakePhone()
        let dcim = phone.add("DCIM", folder: true)
        let camera = phone.add("Camera", in: dcim, folder: true)
        phone.add("one.jpg", in: camera, data: "1")
        phone.add("empty", in: dcim, folder: true)
        let note = phone.add("note.txt", data: "hello")
        try write("old", to: "note.txt")

        let copied = try await transfers(phone).copyToMac([phone.item(dcim), phone.item(note)], into: temp)

        XCTAssertEqual(copied.map(\.lastPathComponent), ["DCIM", "note 2.txt"])
        XCTAssertEqual(try read("DCIM/Camera/one.jpg"), "1")
        XCTAssertEqual(try read("note 2.txt"), "hello")
        XCTAssertEqual(try read("note.txt"), "old")
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("DCIM/empty").path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
    }

    func testCopyToPhoneCopiesFoldersAndRenamesConflicts() async throws {
        let phone = FakePhone()
        let music = phone.add("Music", folder: true)
        phone.add("Album", in: music, folder: true)
        try write("s1", to: "Album/song1.mp3")
        try write("s2", to: "Album/Disc 2/song2.mp3")
        try write("t", to: "track.mp3")

        try await transfers(phone).copyToPhone(
            [temp.appendingPathComponent("Album"), temp.appendingPathComponent("track.mp3")],
            storage: FakePhone.storage, folder: music
        )

        let album = try XCTUnwrap(phone.child(named: "Album 2", in: music))
        let disc = try XCTUnwrap(phone.child(named: "Disc 2", in: album))
        let song2 = try XCTUnwrap(phone.child(named: "song2.mp3", in: disc))
        XCTAssertEqual(phone.nodes[song2]?.data, Data("s2".utf8))
        XCTAssertNotNil(phone.child(named: "song1.mp3", in: album))
        XCTAssertNotNil(phone.child(named: "track.mp3", in: music))
    }

    func testDeleteRemovesFolderContentsFirst() async throws {
        let phone = FakePhone()
        let folder = phone.add("Old", folder: true)
        let inner = phone.add("Inner", in: folder, folder: true)
        phone.add("a.txt", in: inner)
        phone.add("b.txt", in: folder)
        let keep = phone.add("keep.txt")

        try await transfers(phone).delete([phone.item(folder)])

        XCTAssertEqual(Array(phone.nodes.keys), [keep])
        XCTAssertEqual(phone.deleteOrder.last, "Old")
        XCTAssertLessThan(phone.deleteOrder.firstIndex(of: "a.txt")!, phone.deleteOrder.firstIndex(of: "Inner")!)
    }

    func testCancellingStopsTheCopyAndRemovesThePartialFile() async throws {
        let phone = FakePhone()
        let first = phone.add("first.txt", data: "1")
        let second = phone.add("second.txt", data: "2")
        let cancel = CancelFlag()
        cancel.cancel()

        do {
            try await transfers(phone, cancel: cancel).copyToMac([phone.item(first), phone.item(second)], into: temp)
            XCTFail("Expected the copy to be cancelled")
        } catch is CancellationError {}

        let left = try FileManager.default.contentsOfDirectory(atPath: temp.path)
        XCTAssertEqual(left, [])
    }

    func testSizeCounterAddsUpNestedFolders() async throws {
        let phone = FakePhone()
        let dcim = phone.add("DCIM", folder: true)
        let camera = phone.add("Camera", in: dcim, folder: true)
        phone.add("one.jpg", in: camera, data: "12345")
        phone.add("two.jpg", in: camera, data: "123")
        phone.add("notes.txt", in: dcim, data: "12")
        phone.add("empty", in: dcim, folder: true)

        let summary = try await SizeCounter.measure(phone.item(dcim), on: phone)
        XCTAssertEqual(summary, SizeSummary(bytes: 10, files: 3))
    }

    func testProgressFraction() {
        XCTAssertEqual(TransferProgress(title: "", bytesDone: 50, bytesTotal: 200).fraction, 0.25)
        XCTAssertEqual(TransferProgress(title: "", fileNumber: 3, fileCount: 4).fraction, 0.5)
        XCTAssertEqual(TransferProgress(title: "").fraction, 0)
    }
}
