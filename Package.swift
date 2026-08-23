// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteriesIncluded",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BatteriesIncluded", targets: ["BatteriesIncluded"])],
    targets: [
        .executableTarget(
            name: "BatteriesIncluded",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(name: "BatteriesIncludedTests", dependencies: ["BatteriesIncluded"])
    ]
)
