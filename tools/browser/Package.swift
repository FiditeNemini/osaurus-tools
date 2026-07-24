// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusBrowser",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OsaurusBrowser", type: .dynamic, targets: ["OsaurusBrowser"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "OsaurusBrowser",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/OsaurusBrowser",
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "OsaurusBrowserTests",
            dependencies: [
                "OsaurusBrowser",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/OsaurusBrowserTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
