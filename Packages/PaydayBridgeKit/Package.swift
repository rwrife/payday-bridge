// swift-tools-version:6.0
import PackageDescription

// PaydayBridgeKit — pure-domain core for Payday Bridge.
// No UI, no networking, no Apple-only frameworks: Linux-testable by design.
let package = Package(
    name: "PaydayBridgeKit",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "PaydayBridgeKit", targets: ["PaydayBridgeKit"]),
    ],
    targets: [
        .target(name: "PaydayBridgeKit"),
        .testTarget(name: "PaydayBridgeKitTests", dependencies: ["PaydayBridgeKit"], resources: [.copy("Fixtures")]),
    ]
)
