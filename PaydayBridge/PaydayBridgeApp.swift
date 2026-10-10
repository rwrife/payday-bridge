import SwiftUI
import PaydayBridgeKit

/// Payday Bridge app entry point.
///
/// iPhone-only offline payday worksheet for irregular earners (`TARGETED_DEVICE_FAMILY = 1`
/// in every build configuration; CI enforces it pre- and post-build).
/// Zero-network by construction: no network APIs anywhere in app or
/// package sources — CI enforces an empty-allowlist scan.
@main
struct PaydayBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
