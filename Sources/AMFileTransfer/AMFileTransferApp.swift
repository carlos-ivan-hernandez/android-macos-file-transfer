import AppKit
import SwiftUI

@main
@MainActor
enum Entry {
    static func main() {
        // `AMFileTransfer icon <image> <output.icns>` draws this app's own icon. build.sh uses it.
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "icon" {
            do {
                guard let image = NSImage(contentsOfFile: arguments[2]) else { throw IconError.failed }
                try IconMaker.writeICNS(IconMaker.gridIcon(from: image), to: URL(fileURLWithPath: arguments[3]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        AMFileTransferApp.main()
    }
}

struct AMFileTransferApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        Window("AM File Transfer", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 920, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Folder") { model.promptNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.isConnected || model.isBusy)
                Button("Copy to Phone…") { model.chooseFilesForPhone() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(!model.isConnected || model.isBusy)
                Button("Copy to Mac…") { model.copyToMac(model.actionItems) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.actionItems.isEmpty || model.isBusy)
            }
            CommandGroup(before: .toolbar) {
                Button("as List") { model.viewMode = .list }
                    .keyboardShortcut("2")
                Button("as Columns") { model.viewMode = .columns }
                    .keyboardShortcut("3")
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run from `swift run` (no app bundle), the app would otherwise start in the background.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
