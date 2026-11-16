// swift-tools-version: 5.9
import Foundation
import PackageDescription

/// The Mac App Store build is sandboxed and updated by the App Store, so it leaves out Sparkle.
let appStore = ProcessInfo.processInfo.environment["UNIFI_APP_STORE"] == "1"
let appStoreSettings: [SwiftSetting] = appStore ? [.define("APP_STORE")] : []

let package = Package(
    name: "UniFiDesktop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "UniFiDesktop", targets: ["UniFiDesktop"])],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"
        ),
        .target(name: "UniFiCore"),
        .executableTarget(
            name: "UniFiDesktop",
            dependencies: appStore ? ["UniFiCore"] : ["UniFiCore", "Sparkle"],
            swiftSettings: appStoreSettings,
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "UniFiCoreTests", dependencies: ["UniFiCore"]),
        .testTarget(name: "UniFiDesktopTests", dependencies: ["UniFiDesktop"], swiftSettings: appStoreSettings)
    ]
)
