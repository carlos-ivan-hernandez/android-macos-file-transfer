import AMFileTransferKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if model.isConnected {
                BrowserView()
            } else {
                ConnectView()
            }
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            if !alert.message.isEmpty { Text(alert.message) }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        List(selection: $model.storageID) {
            if model.isConnected {
                Section(model.deviceName) {
                    ForEach(model.storages) { storage in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(storage.name, systemImage: "internaldrive")
                            Text("\(formatBytes(storage.freeBytes)) free of \(formatBytes(storage.capacityBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 26)
                        }
                        .padding(.vertical, 2)
                        .tag(storage.id)
                    }
                }
            } else {
                Section("Phone") {
                    Label("Not connected", systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.isBusy)
        .safeAreaInset(edge: .bottom) {
            if model.isConnected {
                Button {
                    model.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Close the connection to the phone and open it again")
                .disabled(model.isBusy)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ConnectView: View {
    @EnvironmentObject private var model: PhoneModel

    private var problem: PhoneError? {
        if case .waiting(let problem) = model.status { return problem }
        return nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cable.connector")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Connect Your Android Phone")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Plug the phone into this Mac with a USB cable.")
                step(2, "Unlock the phone.")
                step(3, "Swipe down from the top of the screen, tap the **USB** notification, and choose **File transfer**.")
                step(4, "If the phone asks to allow access to phone data, tap **Allow**.")
            }
            .frame(maxWidth: 440, alignment: .leading)

            if let problem {
                problemView(problem)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for a phone…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func problemView(_ problem: PhoneError) -> some View {
        VStack(spacing: 10) {
            Label(problem.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if problem == .busy {
                Text("Quit other apps that use the phone, such as OpenMTP, Android File Transfer, Smart Switch, Image Capture, or Photos. macOS's photo import service can also hold on to the phone; **Free Phone from macOS** stops it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Free Phone from macOS") { model.freePhoneFromMacOS() }
            } else if let details = problem.details {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: 440)
            }
            Text("AM File Transfer keeps trying every few seconds.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
