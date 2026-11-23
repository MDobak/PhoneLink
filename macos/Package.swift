// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhoneLink",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PhoneLink", path: "Sources/PhoneLink"),
        // Gives each phone app window its own Dock icon.
        .executableTarget(name: "PhoneLinkDockShim", path: "Shim")
    ]
)
