// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MusterCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "MusterCore",
            targets: ["MusterCore"]
        ),
        .library(
            name: "MusterShellProtocol",
            targets: ["MusterShellProtocol"]
        ),
        .executable(
            name: "MusterShellHost",
            targets: ["MusterShellHost"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "MusterShellProtocol",
            dependencies: []
        ),
        .target(
            name: "MusterCore",
            dependencies: ["MusterShellProtocol"]
        ),
        .executableTarget(
            name: "MusterShellHost",
            dependencies: ["MusterShellProtocol"]
        ),
        .testTarget(
            name: "MusterCoreTests",
            dependencies: ["MusterCore"]
        ),
        .testTarget(
            name: "MusterShellProtocolTests",
            dependencies: ["MusterShellProtocol"]
        ),
    ]
)
