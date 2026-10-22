import AppKit
import PhoneFilesKit
import SwiftUI

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class PhoneModel: ObservableObject {
    enum Status: Equatable {
        /// No phone open. `problem` says why, when a phone was found but couldn't be used.
        case waiting(problem: PhoneError?)
        case connected
    }

    @Published private(set) var status: Status = .waiting(problem: nil)
    @Published private(set) var deviceName = ""
    @Published private(set) var storages: [PhoneStorage] = []
    @Published var storageID: UInt32? {
        didSet {
            guard oldValue != storageID else { return }
            path = []
            selection = []
            reload()
        }
    }

    /// The folders from the storage's top level down to the one being shown.
    @Published private(set) var path: [PhoneItem] = []
    @Published private(set) var items: [PhoneItem] = []
    @Published private(set) var isLoading = false
    @Published var selection = Set<PhoneItem.ID>()
    @Published var sortOrder = [KeyPathComparator(\PhoneItem.name, comparator: String.StandardComparator.localizedStandard)]

    @Published private(set) var transfer: TransferProgress?
    @Published var alert: AlertInfo?
    @Published var pendingDelete: [PhoneItem] = []
    @Published var newFolderPrompt = false
    @Published var newFolderName = ""

    private var connection: MTPConnection?
    private var cancelFlag: CancelFlag?
    private var watchTask: Task<Void, Never>?
    private var connecting = false
    private var loadGeneration = 0

    private static let lastFolderKey = "LastCopyToMacFolder"

    init() {
        watchForPhone()
    }

    // MARK: State for the views

    var isConnected: Bool { status == .connected }
    var isBusy: Bool { transfer != nil }
    var currentFolderID: UInt32 { path.last?.id ?? PhoneFolder.root }
    var currentStorage: PhoneStorage? { storages.first { $0.id == storageID } }

    /// Folders first, each group in the table's sort order.
    var sortedItems: [PhoneItem] {
        items.filter(\.isFolder).sorted(using: sortOrder) + items.filter { !$0.isFolder }.sorted(using: sortOrder)
    }

    var selectedItems: [PhoneItem] { items(for: selection) }

    func items(for ids: Set<PhoneItem.ID>) -> [PhoneItem] {
        sortedItems.filter { ids.contains($0.id) }
    }

    // MARK: Connecting

    /// Looks for a phone every two seconds until one is open.
    func watchForPhone() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isConnected else { return }
                await self.connect()
                if self.isConnected { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func connect() async {
        guard !connecting, connection == nil else { return }
        connecting = true
        defer { connecting = false }

        guard await MTPConnection.phoneAttached() else {
            status = .waiting(problem: nil)
            return
        }
        do {
            let newConnection = try await MTPConnection.connect()
            do {
                let found = try await newConnection.storages()
                connection = newConnection
                deviceName = newConnection.info.name
                storages = found
                status = .connected
                storageID = found.first?.id
            } catch {
                await newConnection.close()
                throw error
            }
        } catch let error as PhoneError {
            status = .waiting(problem: error == .noPhone ? nil : error)
        } catch {
            status = .waiting(problem: .failed(error.localizedDescription, details: ""))
        }
    }

    /// macOS's photo import service (ptpcamerad) often grabs an Android phone as soon as it's plugged in,
    /// which stops anything else from opening it. Stopping it frees the phone; macOS restarts the
    /// service on its own, so the phone is opened right away.
    func freePhoneFromMacOS() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-9", "ptpcamerad"]
        try? process.run()
        process.waitUntilExit()
        Task { await connect() }
    }

    func disconnect() {
        Task {
            await dropConnection()
            watchForPhone()
        }
    }

    private func dropConnection() async {
        cancelFlag?.cancel()
        let old = connection
        connection = nil
        storages = []
        items = []
        path = []
        selection = []
        storageID = nil
        status = .waiting(problem: nil)
        await old?.close()
    }

    // MARK: Browsing

    func reload() {
        Task { await loadItems() }
    }

    func loadItems() async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let connection, let storageID else {
            items = []
            return
        }
        isLoading = true
        do {
            let found = try await connection.list(storage: storageID, folder: currentFolderID)
            guard generation == loadGeneration else { return }
            items = found
            let ids = Set(found.map(\.id))
            selection = selection.filter { ids.contains($0) }
        } catch {
            guard generation == loadGeneration else { return }
            items = []
            await handle(error)
        }
        isLoading = false
    }

    func open(_ item: PhoneItem) {
        guard !isBusy else { return }
        if item.isFolder {
            path.append(item)
            selection = []
            items = []
            reload()
        } else {
            openOnMac(item)
        }
    }

    func goUp() {
        guard !path.isEmpty, !isBusy else { return }
        let left = path.removeLast()
        items = []
        reload()
        selection = [left.id]
    }

    /// Shows the folder at `depth` in the path (0 is the top of the storage).
    func go(toDepth depth: Int) {
        guard depth < path.count, !isBusy else { return }
        path = Array(path.prefix(depth))
        selection = []
        items = []
        reload()
    }

    // MARK: Copying and deleting

    func copyToMac(_ chosen: [PhoneItem]) {
        guard !chosen.isEmpty, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = chosen.count == 1
            ? "Choose where to copy “\(chosen[0].name)”."
            : "Choose where to copy \(chosen.count) items."
        panel.directoryURL = UserDefaults.standard.url(forKey: Self.lastFolderKey)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        UserDefaults.standard.set(destination, forKey: Self.lastFolderKey)

        runTransfer(refreshAfter: false) { transfers in
            let copied = try await transfers.copyToMac(chosen, into: destination)
            NSWorkspace.shared.activateFileViewerSelecting(copied)
        }
    }

    /// Copies a phone file to a temporary folder and opens it in its Mac app.
    func openOnMac(_ item: PhoneItem) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneFiles-\(UUID().uuidString)", isDirectory: true)
        runTransfer(refreshAfter: false) { transfers in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let copied = try await transfers.copyToMac([item], into: folder).first {
                NSWorkspace.shared.open(copied)
            }
        }
    }

    func chooseFilesForPhone() {
        guard isConnected, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Phone"
        panel.message = "Choose files and folders to copy to “\(path.last?.name ?? currentStorage?.name ?? deviceName)”."
        guard panel.runModal() == .OK else { return }
        copyToPhone(panel.urls)
    }

    func copyToPhone(_ urls: [URL]) {
        guard !urls.isEmpty, let storageID, !isBusy else { return }
        let folder = currentFolderID
        runTransfer(refreshAfter: true) { transfers in
            try await transfers.copyToPhone(urls, storage: storageID, folder: folder)
        }
    }

    func confirmDelete(_ chosen: [PhoneItem]) {
        guard !chosen.isEmpty, !isBusy else { return }
        pendingDelete = chosen
    }

    func delete(_ chosen: [PhoneItem]) {
        pendingDelete = []
        guard !chosen.isEmpty else { return }
        selection.subtract(chosen.map(\.id))
        runTransfer(refreshAfter: true) { transfers in
            try await transfers.delete(chosen)
        }
    }

    func promptNewFolder() {
        guard isConnected, !isBusy else { return }
        newFolderName = UniqueName.make(for: "New Folder", isFolder: true) { name in
            items.contains { $0.name.lowercased() == name.lowercased() }
        }
        newFolderPrompt = true
    }

    func createFolder(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let connection, let storageID, !isBusy else { return }
        if name.contains("/") {
            alert = AlertInfo(title: "Can't use that name", message: "Folder names can't contain “/”.")
            return
        }
        if items.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            alert = AlertInfo(title: "Can't use that name", message: "“\(name)” is already in this folder.")
            return
        }
        let folder = currentFolderID
        Task {
            do {
                let created = try await connection.createFolder(named: name, storage: storageID, in: folder)
                await loadItems()
                selection = [created.id]
            } catch {
                await handle(error)
            }
        }
    }

    func cancelTransfer() {
        cancelFlag?.cancel()
    }

    private func runTransfer(refreshAfter: Bool, _ work: @escaping (Transfers) async throws -> Void) {
        guard let connection, transfer == nil else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        transfer = TransferProgress(title: "Preparing…")
        let transfers = Transfers(device: connection, cancel: flag) { [weak self] progress in
            Task { @MainActor in
                // Ignore late updates after the transfer is over.
                guard let self, self.cancelFlag === flag else { return }
                self.transfer = progress
            }
        }
        Task {
            do {
                try await work(transfers)
            } catch is CancellationError {
            } catch {
                await handle(error)
            }
            if cancelFlag === flag {
                cancelFlag = nil
                transfer = nil
            }
            if refreshAfter, self.connection === connection { await loadItems() }
        }
    }

    /// Shows an error, or goes back to waiting if the phone was unplugged.
    private func handle(_ error: Error) async {
        if connection != nil, !(await MTPConnection.phoneAttached()) {
            await dropConnection()
            watchForPhone()
            return
        }
        var message = (error as? PhoneError)?.details ?? ""
        if message.count > 600 { message = String(message.prefix(600)) + "…" }
        alert = AlertInfo(title: error.localizedDescription, message: message)
    }
}
