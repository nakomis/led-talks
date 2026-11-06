// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LEDTalksKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LEDTalksKit", targets: ["LEDTalksKit"]),
    ],
    targets: [
        .target(name: "LEDTalksKit"),
        .testTarget(name: "LEDTalksKitTests", dependencies: ["LEDTalksKit"]),
    ]
)
