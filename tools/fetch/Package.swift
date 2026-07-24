// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusFetch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusFetch", type: .dynamic, targets: ["OsaurusFetch"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "OsaurusFetch",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/OsaurusFetch"
        ),
        .testTarget(
            name: "OsaurusFetchTests",
            dependencies: [
                "OsaurusFetch",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/OsaurusFetchTests"
        ),
    ]
)
