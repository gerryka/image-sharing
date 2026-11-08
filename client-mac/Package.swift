// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImgShareCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ImgShareCore", targets: ["ImgShareCore"]),
    ],
    targets: [
        .target(name: "ImgShareCore"),
        .testTarget(
            name: "ImgShareCoreTests",
            dependencies: ["ImgShareCore"],
            resources: [.copy("Resources")]
        ),
    ]
)
