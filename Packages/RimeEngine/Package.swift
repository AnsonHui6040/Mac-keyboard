// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RimeEngine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RimeEngine", targets: ["RimeEngine"])
    ],
    dependencies: [
        .package(path: "../RemoteKeyboardCore")
    ],
    targets: [
        .binaryTarget(name: "RimeC", path: "Artifacts/RimeC.xcframework"),
        .target(
            name: "RimeEngine",
            dependencies: [
                "RimeC",
                .product(name: "RemoteKeyboardCore", package: "RemoteKeyboardCore")
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .testTarget(
            name: "RimeEngineTests",
            dependencies: ["RimeEngine"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
