// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FitHair",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FitHair", targets: ["FitHair"])
    ],
    targets: [
        .executableTarget(
            name: "FitHair",
            path: "Sources/FitHair",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Embed Info.plist so camera permission works even when run straight from Xcode / `swift run`.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist"])
            ]
        ),
        .testTarget(
            name: "FitHairTests",
            dependencies: ["FitHair"],
            path: "Tests/FitHairTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
