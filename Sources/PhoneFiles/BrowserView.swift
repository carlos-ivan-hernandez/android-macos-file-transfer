import AppKit
import PhoneFilesKit
import SwiftUI
import UniformTypeIdentifiers

/// The files in the current phone folder.
struct BrowserView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            PathBar()
            Divider()
            FileTable()
                .overlay { emptyState }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(2)
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    guard !model.isBusy else { return false }
                    Task { @MainActor in
                        var urls: [URL] = []
                        for provider in providers {
                            if let url = await provider.loadFileURL() { urls.append(url) }
                        }
                        model.copyToPhone(urls)
                    }
                    return true
                }
            Divider()
            if let transfer = model.transfer {
                TransferBar(progress: transfer)
            } else {
                StatusBar()
            }
        }
        .navigationTitle(model.path.last?.name ?? model.currentStorage?.name ?? model.deviceName)
        .toolbar { toolbar }
        .alert("New Folder", isPresented: $model.newFolderPrompt) {
            TextField("Name", text: $model.newFolderName)
            Button("Create") { model.createFolder(named: model.newFolderName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new folder.")
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { !model.pendingDelete.isEmpty },
                set: { if !$0 { model.pendingDelete = [] } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingDelete
        ) { items in
            Button("Delete", role: .destructive) { model.delete(items) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They're deleted from the phone right away. This can't be undone.")
        }
    }

    private var deleteTitle: String {
        let items = model.pendingDelete
        return items.count == 1 ? "Delete “\(items[0].name)”?" : "Delete \(items.count) items?"
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.items.isEmpty {
            if model.isLoading {
                ProgressView()
            } else {
                VStack(spacing: 6) {
                    Text("This folder is empty").foregroundStyle(.secondary)
                    Text("Drag files here to copy them to the phone.").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.goUp() } label: {
                Label("Enclosing Folder", systemImage: "chevron.left")
            }
            .help("Go to the enclosing folder (⌘↑)")
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(model.path.isEmpty || model.isBusy)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.reload() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            .keyboardShortcut("r")
            .disabled(model.isBusy)

            Button { model.promptNewFolder() } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New folder (⇧⌘N)")
            .disabled(model.isBusy)

            Button { model.chooseFilesForPhone() } label: {
                Label("Copy to Phone", systemImage: "square.and.arrow.up")
            }
            .help("Copy files from this Mac to the phone (⇧⌘U)")
            .disabled(model.isBusy)

            Button { model.copyToMac(model.selectedItems) } label: {
                Label("Copy to Mac", systemImage: "square.and.arrow.down")
            }
            .help("Copy the selected items to this Mac (⇧⌘D)")
            .disabled(model.selection.isEmpty || model.isBusy)

            Button { model.confirmDelete(model.selectedItems) } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete the selected items from the phone (⌘⌫)")
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selection.isEmpty || model.isBusy)
        }
    }
}

struct FileTable: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Table(model.sortedItems, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 360)

            TableColumn("Date Modified", value: \.sortDate) { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "—" : formatBytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .disabled(model.isBusy)
        .contextMenu(forSelectionType: PhoneItem.ID.self) { ids in
            let items = model.items(for: ids)
            if items.isEmpty {
                Button("New Folder") { model.promptNewFolder() }
                Button("Copy to Phone…") { model.chooseFilesForPhone() }
            } else {
                if items.count == 1 {
                    Button(items[0].isFolder ? "Open" : "Open on Mac") { model.open(items[0]) }
                    Divider()
                }
                Button("Copy to Mac…") { model.copyToMac(items) }
                Divider()
                Button("Delete…", role: .destructive) { model.confirmDelete(items) }
            }
        } primaryAction: { ids in
            let items = model.items(for: ids)
            if items.count == 1 { model.open(items[0]) }
        }
        .onDeleteCommand { model.confirmDelete(model.selectedItems) }
    }
}

/// The current folder's place in the storage, with each level clickable.
struct PathBar: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        HStack(spacing: 4) {
            crumb(model.currentStorage?.name ?? "Phone", depth: 0, icon: "internaldrive")
            ForEach(Array(model.path.enumerated()), id: \.element.id) { index, folder in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                crumb(folder.name, depth: index + 1, icon: "folder")
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func crumb(_ name: String, depth: Int, icon: String) -> some View {
        let isCurrent = depth == model.path.count
        return Button { model.go(toDepth: depth) } label: {
            Label(name, systemImage: icon)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || model.isBusy)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        HStack {
            Text(summary)
            Spacer()
            if let storage = model.currentStorage {
                Text("\(formatBytes(storage.freeBytes)) available")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var summary: String {
        let count = model.items.count
        let selected = model.selection.count
        let items = count == 1 ? "1 item" : "\(count) items"
        return selected > 0 ? "\(selected) of \(items) selected" : items
    }
}

struct TransferBar: View {
    @EnvironmentObject private var model: PhoneModel
    let progress: TransferProgress

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if progress.fileCount > 0 {
                    ProgressView(value: progress.fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if progress.bytesTotal > 0 {
                    Text("\(formatBytes(progress.bytesDone)) of \(formatBytes(progress.bytesTotal))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button("Cancel") { model.cancelTransfer() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headline: String {
        var text = progress.title
        if progress.fileCount > 1 { text += " \(progress.fileNumber) of \(progress.fileCount)" }
        if !progress.fileName.isEmpty { text += ": \(progress.fileName)" }
        return text
    }
}

enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: PhoneItem) -> NSImage {
        let key = item.isFolder ? "/folder" : (item.name as NSString).pathExtension.lowercased()
        if let icon = cache[key] { return icon }
        let type: UTType = item.isFolder ? .folder : (UTType(filenameExtension: key) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }
}

extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
