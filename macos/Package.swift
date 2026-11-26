// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhoneLink",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PhoneLink", dependencies: ["CPhoneUSB"], path: "Sources/PhoneLink"),
        // USB access to Android phones (Android Open Accessory) through IOKit.
        .target(name: "CPhoneUSB", path: "Sources/CPhoneUSB",
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        // Gives each phone app window its own Dock icon.
        .executableTarget(name: "PhoneLinkDockShim", path: "Shim"),
        // The MCP server for local agents: stdio to the Unix socket of the app (AgentServer).
        .executableTarget(name: "PhoneLinkMCP", path: "Sources/PhoneLinkMCP"),
        .testTarget(name: "PhoneLinkTests", dependencies: ["PhoneLink"], path: "Tests/PhoneLinkTests")
    ]
)
