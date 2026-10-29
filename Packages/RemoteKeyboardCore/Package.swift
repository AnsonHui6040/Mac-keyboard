// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteKeyboardCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RemoteKeyboardCore", targets: ["RemoteKeyboardCore"])
    ],
    targets: [
        .target(name: "RemoteKeyboardCore"),
        .testTarget(name: "RemoteKeyboardCoreTests", dependencies: ["RemoteKeyboardCore"])
    ],
    swiftLanguageModes: [.v6]
)
