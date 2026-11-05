// swift-tools-version: 5.9
import PackageDescription

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
            dependencies: ["UniFiCore", "Sparkle"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "UniFiCoreTests", dependencies: ["UniFiCore"]),
        .testTarget(name: "UniFiDesktopTests", dependencies: ["UniFiDesktop"])
    ]
)
