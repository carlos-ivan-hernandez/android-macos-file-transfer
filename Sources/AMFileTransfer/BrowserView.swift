import AppKit
import AMFileTransferKit
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
            Group {
                switch model.viewMode {
                case .list: FileTable().overlay { emptyState }
                case .columns: ColumnBrowser()
                }
            }
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
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $model.viewMode) {
                Label("List", systemImage: "list.bullet").tag(PhoneModel.ViewMode.list)
                Label("Columns", systemImage: "rectangle.split.3x1").tag(PhoneModel.ViewMode.columns)
            }
            .pickerStyle(.segmented)
            .help("Show items as a list (⌘2) or in columns (⌘3)")
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

            Button { model.copyToMac(model.actionItems) } label: {
                Label("Copy to Mac", systemImage: "square.and.arrow.down")
            }
            .help("Copy the selected items to this Mac (⇧⌘D)")
            .disabled(model.actionItems.isEmpty || model.isBusy)

            Button { model.confirmDelete(model.actionItems) } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete the selected items from the phone (⌘⌫)")
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.actionItems.isEmpty || model.isBusy)
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
                Text(item.isFolder ? model.folderSizes[item.id].map { formatBytes($0.bytes) } ?? "—" : formatBytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .disabled(model.isBusy)
        .contextMenu(forSelectionType: PhoneItem.ID.self) { ids in
            ItemMenu(items: model.items(for: ids), canAddHere: true)
        } primaryAction: { ids in
            let items = model.items(for: ids)
            if items.count == 1 { model.open(items[0]) }
        }
        .onDeleteCommand { model.confirmDelete(model.selectedItems) }
    }
}

/// The right-click menu for rows in the list and in columns.
struct ItemMenu: View {
    @EnvironmentObject private var model: PhoneModel
    let items: [PhoneItem]
    /// Whether New Folder and Copy to Phone make sense here (they add to the current folder).
    let canAddHere: Bool

    var body: some View {
        if items.isEmpty {
            if canAddHere {
                Button("New Folder") { model.promptNewFolder() }
                Button("Copy to Phone…") { model.chooseFilesForPhone() }
            }
        } else {
            if items.count == 1, !items[0].isFolder {
                Button("Open on Mac") { model.open(items[0]) }
                Divider()
            } else if items.count == 1, model.viewMode == .list {
                Button("Open") { model.open(items[0]) }
                Divider()
            }
            Button("Copy to Mac…") { model.copyToMac(items) }
            Divider()
            Button("Delete…", role: .destructive) { model.confirmDelete(items) }
        }
    }
}

/// Finder-style columns: one per open folder, plus a preview of a selected file.
/// The arrow keys move through the columns while the browser has keyboard focus.
struct ColumnBrowser: View {
    @EnvironmentObject private var model: PhoneModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0...model.path.count, id: \.self) { column in
                        BrowserColumn(column: column, browserFocused: focused) { focused = true }
                            .frame(width: 240)
                            .id(column)
                        Divider()
                    }
                    if let file = model.previewItem {
                        FilePreview(item: file)
                            .frame(width: 280)
                            .id("preview")
                        Divider()
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .onChange(of: model.path.count) { count in
                withAnimation { proxy.scrollTo(count, anchor: .trailing) }
            }
            .onChange(of: model.previewItem?.id) { id in
                if id != nil { withAnimation { proxy.scrollTo("preview", anchor: .trailing) } }
            }
        }
        .focusable()
        .focused($focused)
        .hideFocusRing()
        .onMoveCommand { direction in model.moveInColumns(direction) }
        .onDeleteCommand { model.confirmDelete(model.actionItems) }
        .onAppear { focused = true }
        .disabled(model.isBusy)
    }
}

struct BrowserColumn: View {
    @EnvironmentObject private var model: PhoneModel
    let column: Int
    let browserFocused: Bool
    /// Gives the browser keyboard focus, so the arrow keys work after a click.
    let focusBrowser: () -> Void

    var body: some View {
        let rows = model.columnItems(column)
        let selected = model.columnSelection(column)
        // Like Finder, the column with the cursor shows its selection in the accent color.
        let emphasized = browserFocused && column == max(model.cursorColumn, 0)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { item in
                        ColumnRow(item: item, isSelected: selected.contains(item.id), emphasized: emphasized)
                            .id(item.id)
                            .onTapGesture { click(item) }
                            .contextMenu {
                                // Right-clicking a selected row acts on the whole selection.
                                let chosen = selected.contains(item.id) ? rows.filter { selected.contains($0.id) } : [item]
                                ItemMenu(items: chosen, canAddHere: false)
                            }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
            .onChange(of: selected) { ids in
                guard let id = rows.first(where: { ids.contains($0.id) })?.id else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) }
            }
        }
        .background {
            // Right-clicking empty space in the last column adds to that folder.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { focusBrowser() }
                .contextMenu {
                    if column == model.path.count { ItemMenu(items: [], canAddHere: true) }
                }
        }
        .overlay {
            if rows.isEmpty {
                if model.isColumnLoading(column) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Empty").foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func click(_ item: PhoneItem) {
        focusBrowser()
        let flags = NSEvent.modifierFlags
        model.click(
            item, inColumn: column,
            toggle: flags.contains(.command), range: flags.contains(.shift),
            double: (NSApp.currentEvent?.clickCount ?? 1) >= 2
        )
    }
}

struct ColumnRow: View {
    let item: PhoneItem
    let isSelected: Bool
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(for: item))
                .resizable()
                .frame(width: 16, height: 16)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if item.isFolder {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected && emphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(isSelected && emphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.25)))
            }
        }
        .contentShape(Rectangle())
    }
}

extension View {
    /// Keyboard focus is shown by the selection color instead of a ring around the browser.
    @ViewBuilder
    func hideFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

/// Details of the selected file, shown as the last column.
struct FilePreview: View {
    @EnvironmentObject private var model: PhoneModel
    let item: PhoneItem

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: FileIcons.icon(for: item))
                .resizable()
                .frame(width: 96, height: 96)
            Text(item.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Kind").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(kind)
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(formatBytes(item.size))
                }
                if let modified = item.modified {
                    GridRow {
                        Text("Modified").foregroundStyle(.secondary)
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .font(.callout)
            HStack {
                Button("Open on Mac") { model.open(item) }
                Button("Copy to Mac…") { model.copyToMac([item]) }
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var kind: String {
        let ext = (item.name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? "File" : ext.uppercased() + " file")
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
        HStack(spacing: 6) {
            if let info = model.sizeInfo {
                Text(name(of: info))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = info.summary {
                    Text(describe(size, folders: info.items.contains(where: \.isFolder)))
                        .layoutPriority(1)
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Calculating size…")
                        .layoutPriority(1)
                }
            } else {
                Text(summary)
            }
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

    private func name(of info: SizeInfo) -> String {
        info.items.count == 1 ? "“\(info.items[0].name)”:" : "\(info.items.count) items selected:"
    }

    /// "3.2 MB", or with folders, "1.2 GB in 340 files".
    private func describe(_ size: SizeSummary, folders: Bool) -> String {
        guard folders else { return formatBytes(size.bytes) }
        let files = size.files == 1 ? "1 file" : "\(size.files.formatted()) files"
        return "\(formatBytes(size.bytes)) in \(files)"
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
