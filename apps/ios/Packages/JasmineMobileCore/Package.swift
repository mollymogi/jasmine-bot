// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JasmineMobileCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "JasmineMobileCore",
            targets: ["JasmineMobileCore"]
        )
    ],
    targets: [
        .target(
            name: "JasmineMobileCore"
        ),
        .executableTarget(
            name: "JasmineMobileCoreCheck",
            dependencies: ["JasmineMobileCore"]
        ),
        .testTarget(
            name: "JasmineMobileCoreTests",
            dependencies: ["JasmineMobileCore"]
        )
    ]
)
