// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MouseNavigate",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MouseNavigate", targets: ["MouseNavigate"])
    ],
    targets: [
        // Pure logic with no AppKit/CoreGraphics dependency, so it can be unit tested.
        .target(name: "MouseNavigateCore"),
        .executableTarget(
            name: "MouseNavigate",
            dependencies: ["MouseNavigateCore"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "MouseNavigateCoreTests",
            dependencies: ["MouseNavigateCore"]
        )
    ]
)
