// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusSearch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusSearch", type: .dynamic, targets: ["OsaurusSearch"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "OsaurusSearch",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/OsaurusSearch"
        ),
        .testTarget(
            name: "OsaurusSearchTests",
            dependencies: [
                "OsaurusSearch",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/OsaurusSearchTests"
        ),
    ]
)
