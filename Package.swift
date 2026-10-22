// swift-tools-version:5.9
import Foundation
import PackageDescription

// libusb and libmtp are built from source into .deps/ by scripts/build-libmtp.sh, for the same
// minimum macOS version as the app, and linked in statically. Run that script once before
// `swift build`, `swift run` or `swift test`. (build.sh runs it for you.)
let deps = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".deps").path

let libmtpLinking: [LinkerSetting] = [
    .unsafeFlags(["-L\(deps)/lib"]),
    .linkedLibrary("mtp"),
    .linkedLibrary("usb-1.0"),
    // What libmtp and libusb use from macOS.
    .linkedLibrary("iconv", .when(platforms: [.macOS])),
    .linkedLibrary("objc", .when(platforms: [.macOS])),
    .linkedFramework("IOKit", .when(platforms: [.macOS])),
    .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
    .linkedFramework("Security", .when(platforms: [.macOS])),
]

let package = Package(
    name: "AMFileTransfer",
    platforms: [.macOS(.v13)],  // keep in step with MIN_MACOS in scripts/build-libmtp.sh
    targets: [
        // libmtp, the C library OpenMTP also uses to talk to Android phones over USB. Its header
        // is copied into Sources/CLibMTP/include by build-libmtp.sh.
        .target(name: "CLibMTP", linkerSettings: libmtpLinking),
        // Foundation-only logic: the libmtp wrapper and the copy/delete engine.
        .target(name: "AMFileTransferKit", dependencies: ["CLibMTP"], linkerSettings: libmtpLinking),
        // The SwiftUI app.
        .executableTarget(name: "AMFileTransfer", dependencies: ["AMFileTransferKit"], linkerSettings: libmtpLinking),
        .testTarget(name: "AMFileTransferKitTests", dependencies: ["AMFileTransferKit"], linkerSettings: libmtpLinking),
    ]
)
