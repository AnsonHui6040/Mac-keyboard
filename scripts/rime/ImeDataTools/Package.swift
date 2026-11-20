// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImeDataTools",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ImeData", targets: ["ImeData"]),
        .executable(name: "make-ime-dicts", targets: ["make-ime-dicts"])
    ],
    targets: [
        .target(name: "ImeData"),
        .executableTarget(name: "make-ime-dicts", dependencies: ["ImeData"]),
        .testTarget(name: "ImeDataTests", dependencies: ["ImeData"])
    ],
    swiftLanguageModes: [.v6]
)
