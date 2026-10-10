import SwiftUI
import PaydayBridgeKit

/// Launch-only skeleton. The worksheet flow (issue #4) replaces this;
/// presentation will compose through PaydayWorkspaceLayout (issue #5).
struct ContentView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Payday Bridge")
                    .font(.largeTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Plan the gap between paydays.")
                    .font(.title2)
                Text(PaydayBridgeKit.planningDisclaimer)
                Text("Worksheet editing is not available in this skeleton.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
