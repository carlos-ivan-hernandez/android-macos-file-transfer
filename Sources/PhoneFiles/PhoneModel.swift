import AppKit
import PhoneFilesKit
import SwiftUI

/// The size of the selected items. `summary` is nil while folders are still being added up.
struct SizeInfo: Equatable {
    let items: [PhoneItem]
    var summary: SizeSummary?
}

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

    enum ViewMode: String {
        case list, columns
    }

    @Published private(set) var status: Status = .waiting(problem: nil)
    @Published private(set) var deviceName = ""
    @Published private(set) var storages: [PhoneStorage] = []
    @Published var storageID: UInt32? {
        didSet {
            guard oldValue != storageID else { return }
            listings = [:]
            path = []
            selection = []
            navigated()
        }
    }

    @Published var viewMode: ViewMode {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey)
            loadMissingFolders()
            updateSizeInfo()
        }
    }

    /// The folders from the storage's top level down to the current folder. In column view,
    /// each one is a column, and the last one is highlighted.
    @Published private(set) var path: [PhoneItem] = [] {
        didSet { updateSizeInfo() }
    }
    /// What's in each folder that has been read, by folder ID.
    @Published private(set) var listings: [UInt32: [PhoneItem]] = [:]
    @Published private(set) var loadingFolders: Set<UInt32> = []
    /// Selected items in the current folder.
    @Published var selection = Set<PhoneItem.ID>() {
        didSet { updateSizeInfo() }
    }
    @Published var sortOrder = [KeyPathComparator(\PhoneItem.name, comparator: String.StandardComparator.localizedStandard)]

    @Published private(set) var transfer: TransferProgress?
    @Published var alert: AlertInfo?
    @Published var pendingDelete: [PhoneItem] = []
    @Published var newFolderPrompt = false
    @Published var newFolderName = ""
    @Published private(set) var sizeInfo: SizeInfo?
    /// Folder sizes added up so far, by folder ID. Cleared on refresh and after changes.
    @Published private(set) var folderSizes: [UInt32: SizeSummary] = [:]

    private var connection: MTPConnection?
    private var usbWatcher: USBRemovalWatcher?
    private var cancelFlag: CancelFlag?
    private var watchTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var connecting = false
    private var loadGenerations: [UInt32: Int] = [:]

    private static let lastFolderKey = "LastCopyToMacFolder"
    private static let viewModeKey = "ViewMode"

    init() {
        viewMode = UserDefaults.standard.string(forKey: Self.viewModeKey).flatMap(ViewMode.init) ?? .list
        watchForPhone()
    }

    // MARK: State for the views

    var isConnected: Bool { status == .connected }
    var isBusy: Bool { transfer != nil }
    var currentFolderID: UInt32 { path.last?.id ?? PhoneFolder.root }
    var currentStorage: PhoneStorage? { storages.first { $0.id == storageID } }

    /// What's in the current folder.
    var items: [PhoneItem] { listings[currentFolderID] ?? [] }
    var isLoading: Bool { loadingFolders.contains(currentFolderID) }
    var sortedItems: [PhoneItem] { sorted(items) }
    var selectedItems: [PhoneItem] { items(for: selection) }

    /// What the toolbar's Copy to Mac and Delete act on. In column view, with nothing selected in
    /// the last column, that's the highlighted folder, as in Finder.
    var actionItems: [PhoneItem] {
        if !selection.isEmpty { return selectedItems }
        if viewMode == .columns, let folder = path.last { return [folder] }
        return []
    }

    /// The single selected file, shown in column view's preview.
    var previewItem: PhoneItem? {
        guard selection.count == 1 else { return nil }
        return items.first { selection.contains($0.id) && !$0.isFolder }
    }

    func items(for ids: Set<PhoneItem.ID>) -> [PhoneItem] {
        sortedItems.filter { ids.contains($0.id) }
    }

    /// Folders first, each group in the table's sort order.
    func sorted(_ items: [PhoneItem]) -> [PhoneItem] {
        items.filter(\.isFolder).sorted(using: sortOrder) + items.filter { !$0.isFolder }.sorted(using: sortOrder)
    }

    // MARK: Columns

    /// The folder shown in each column: the top of the storage, then each folder in `path`.
    var columnFolders: [UInt32] { [PhoneFolder.root] + path.map(\.id) }

    func columnItems(_ column: Int) -> [PhoneItem] {
        guard column < columnFolders.count else { return [] }
        return sorted(listings[columnFolders[column]] ?? [])
    }

    func isColumnLoading(_ column: Int) -> Bool {
        column < columnFolders.count && loadingFolders.contains(columnFolders[column])
    }

    /// The highlighted rows in a column: the open folder for earlier columns, the selection for the last.
    func columnSelection(_ column: Int) -> Set<PhoneItem.ID> {
        if column < path.count { return [path[column].id] }
        return column == path.count ? selection : []
    }

    /// Choosing a single folder in a column opens it in the next column. Anything else closes the
    /// columns to its right and becomes the selection.
    func selectInColumn(_ column: Int, _ ids: Set<PhoneItem.ID>) {
        guard !isBusy, column <= path.count, ids != columnSelection(column) else { return }
        let columnItems = listings[columnFolders[column]] ?? []
        path = Array(path.prefix(column))
        if ids.count == 1, let folder = columnItems.first(where: { ids.contains($0.id) }), folder.isFolder {
            path.append(folder)
            selection = []
            navigated()
        } else {
            selection = ids
        }
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
                usbWatcher = USBRemovalWatcher(
                    vendorID: newConnection.info.vendorID, productID: newConnection.info.productID
                ) { [weak self] in
                    Task { @MainActor in self?.phoneUnplugged() }
                }
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

    /// Closes the connection and opens the phone again.
    func reconnect() {
        let closing = dropConnection()
        Task {
            await closing?.value
            watchForPhone()
        }
    }

    private func phoneUnplugged() {
        guard connection != nil else { return }
        if isBusy {
            alert = AlertInfo(
                title: "The phone was disconnected",
                message: "The copy stopped. Files that finished copying were kept."
            )
        }
        let closing = dropConnection()
        Task {
            await closing?.value
            watchForPhone()
        }
    }

    /// Clears everything about the phone right away. Returns the task that closes the connection,
    /// which waits for libmtp to finish its current call.
    @discardableResult
    private func dropConnection() -> Task<Void, Never>? {
        cancelFlag?.cancel()
        cancelFlag = nil
        transfer = nil
        usbWatcher = nil
        let old = connection
        connection = nil
        storageID = nil
        storages = []
        listings = [:]
        loadingFolders = []
        path = []
        selection = []
        pendingDelete = []
        newFolderPrompt = false
        status = .waiting(problem: nil)
        forgetSizes()
        guard let old else { return nil }
        return Task { await old.close() }
    }

    // MARK: Browsing

    /// Reads the folders being shown again.
    func reload() {
        let folders = viewMode == .columns ? columnFolders : [currentFolderID]
        forgetSizes()
        Task {
            for folder in folders { await load(folder) }
        }
    }

    /// After `path` changes: reads the current folder, plus any column that hasn't been read yet.
    private func navigated() {
        Task { await load(currentFolderID) }
        loadMissingFolders()
    }

    private func loadMissingFolders() {
        guard viewMode == .columns else { return }
        for folder in columnFolders where listings[folder] == nil && !loadingFolders.contains(folder) {
            Task { await load(folder) }
        }
    }

    private func load(_ folder: UInt32) async {
        guard let connection, let storageID else { return }
        let generation = (loadGenerations[folder] ?? 0) + 1
        loadGenerations[folder] = generation
        loadingFolders.insert(folder)
        let result: Result<[PhoneItem], Error>
        do {
            result = .success(try await connection.list(storage: storageID, folder: folder))
        } catch {
            result = .failure(error)
        }
        // Ignore the result if the folder was read again since, or the phone changed.
        guard loadGenerations[folder] == generation, self.connection === connection else { return }
        loadingFolders.remove(folder)
        switch result {
        case .success(let found):
            listings[folder] = found
            if folder == currentFolderID {
                let ids = Set(found.map(\.id))
                selection = selection.filter { ids.contains($0) }
            }
        case .failure(let error):
            await handle(error)
        }
    }

    func open(_ item: PhoneItem) {
        guard !isBusy else { return }
        if item.isFolder {
            if path.last?.id != item.id { path.append(item) }
            selection = []
            navigated()
        } else {
            openOnMac(item)
        }
    }

    func goUp() {
        guard !path.isEmpty, !isBusy else { return }
        let left = path.removeLast()
        // In column view the new last folder is highlighted; in list view the folder just left is.
        selection = viewMode == .list ? [left.id] : []
        navigated()
    }

    /// Shows the folder at `depth` in the path (0 is the top of the storage).
    func go(toDepth depth: Int) {
        guard depth < path.count, !isBusy else { return }
        path = Array(path.prefix(depth))
        selection = []
        navigated()
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
        let ids = Set(chosen.map(\.id))
        // Close any open column that's being deleted.
        if let index = path.firstIndex(where: { ids.contains($0.id) }) {
            path = Array(path.prefix(index))
        }
        selection.subtract(ids)
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
                await load(folder)
                if folder == currentFolderID { selection = [created.id] }
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
            if refreshAfter, self.connection === connection {
                forgetSizes()
                await load(currentFolderID)
            }
        }
    }

    // MARK: Sizes

    /// Works out the size of what's selected (in column view, the highlighted folder when nothing
    /// else is). Folders are added up in the background.
    private func updateSizeInfo() {
        let chosen = actionItems
        let ids = chosen.map(\.id)
        guard ids != sizeInfo?.items.map(\.id) else { return }
        sizeTask?.cancel()
        sizeTask = nil
        guard !chosen.isEmpty else {
            sizeInfo = nil
            return
        }
        let unmeasured = chosen.filter { $0.isFolder && folderSizes[$0.id] == nil }
        guard !unmeasured.isEmpty, let connection else {
            sizeInfo = SizeInfo(items: chosen, summary: totalSize(of: chosen))
            return
        }
        sizeInfo = SizeInfo(items: chosen, summary: nil)
        sizeTask = Task {
            do {
                for folder in unmeasured {
                    let size = try await SizeCounter.measure(folder, on: connection)
                    guard !Task.isCancelled, self.connection === connection else { return }
                    folderSizes[folder.id] = size
                }
                guard !Task.isCancelled, sizeInfo?.items.map(\.id) == ids else { return }
                sizeInfo = SizeInfo(items: chosen, summary: totalSize(of: chosen))
            } catch {
                // Cancelled, or the folder couldn't be read: show no size rather than a wrong one.
                if !Task.isCancelled, sizeInfo?.items.map(\.id) == ids { sizeInfo = nil }
            }
        }
    }

    private func totalSize(of items: [PhoneItem]) -> SizeSummary {
        items.reduce(SizeSummary()) { total, item in
            total + (item.isFolder ? folderSizes[item.id] ?? SizeSummary() : SizeSummary(bytes: item.size, files: 1))
        }
    }

    /// Drops saved folder sizes, which may be out of date, and works out the selection's size again.
    private func forgetSizes() {
        sizeTask?.cancel()
        sizeTask = nil
        folderSizes = [:]
        sizeInfo = nil
        updateSizeInfo()
    }

    /// Shows an error, or goes back to waiting if the phone was unplugged.
    private func handle(_ error: Error) async {
        // The phone is already gone; `phoneUnplugged` has dealt with it.
        guard connection != nil else { return }
        if !(await MTPConnection.phoneAttached()) {
            phoneUnplugged()
            return
        }
        var message = (error as? PhoneError)?.details ?? ""
        if message.count > 600 { message = String(message.prefix(600)) + "…" }
        alert = AlertInfo(title: error.localizedDescription, message: message)
    }
}
