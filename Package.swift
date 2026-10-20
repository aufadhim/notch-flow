// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchFlow",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NotchFlow", targets: ["NotchFlow"])],
    targets: [
        .executableTarget(name: "NotchFlow")
    ]
)
