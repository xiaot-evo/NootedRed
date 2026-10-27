// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NootedRedTool",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "NootedRedTool", targets: ["NootedRedTool"])
    ],
    targets: [
        .executableTarget(
            name: "NootedRedTool",
            path: "Sources/NootedRedTool"
        )
    ],
    swiftLanguageVersions: [.v5]
)
