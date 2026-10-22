import AppKit
import SwiftUI

@main
struct PhoneFilesApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        Window("PhoneFiles", id: "main") {
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
                Button("Copy to Mac…") { model.copyToMac(model.selectedItems) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.selectedItems.isEmpty || model.isBusy)
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
