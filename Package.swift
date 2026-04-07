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
        .executableTarget(
            name: "MouseNavigate",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
