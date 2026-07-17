// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusTime",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusTime", type: .dynamic, targets: ["OsaurusTime"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "OsaurusTime",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/OsaurusTime"
        ),
        .testTarget(
            name: "OsaurusTimeTests",
            dependencies: [
                "OsaurusTime",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/OsaurusTimeTests"
        ),
    ]
)
