// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneFiles",
    platforms: [.macOS(.v13)],
    targets: [
        // libmtp, the C library OpenMTP also uses to talk to Android phones over USB.
        .systemLibrary(
            name: "CLibMTP",
            pkgConfig: "libmtp",
            providers: [.brew(["libmtp"]), .apt(["libmtp-dev"])]
        ),
        // Foundation-only logic: the libmtp wrapper and the copy/delete engine.
        .target(name: "PhoneFilesKit", dependencies: ["CLibMTP"]),
        // The SwiftUI app.
        .executableTarget(name: "PhoneFiles", dependencies: ["PhoneFilesKit"]),
        .testTarget(name: "PhoneFilesKitTests", dependencies: ["PhoneFilesKit"]),
    ]
)
