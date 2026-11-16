// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WispCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WispCore", targets: ["WispCore"]),
    ],
    targets: [
        .target(name: "WispCore"),
        .testTarget(name: "WispCoreTests", dependencies: ["WispCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
