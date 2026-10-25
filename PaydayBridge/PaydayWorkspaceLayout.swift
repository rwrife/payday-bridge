import SwiftUI

/// State that must survive orientation and future layout changes (issue #5).
/// The planned iPhone Duo adapter will share one instance between the display
/// showing the timeline and the display showing controls so neither forks a
/// private copy; today a single @State in ContentView plays that role.
struct PaydayWorkspaceSelection: Equatable {
    var selectedOccurrenceKey: String?
    var draftMode = false
}

/// Composition seam for the dual-screen posture (PLAN.md "Dual-screen seam").
///
/// Today this renders the standard single-screen iPhone arrangement: timeline
/// sections first, funding/draft control sections second, in one scroll
/// context. The future iPhone Duo target keeps the dated bill timeline on one
/// display while the other hosts envelope allocation and the what-if
/// comparison; it will re-host these same two builders behind a fold adapter.
/// No fold SDK API is available or used today, and native iPad support stays
/// disabled (TARGETED_DEVICE_FAMILY = 1).
struct PaydayWorkspaceLayout<Timeline: View, Controls: View>: View {
    @ViewBuilder var timeline: () -> Timeline
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        // Parent owns scroll context and selection; composition never resets @State.
        timeline()
        controls()
    }
}

extension View {
    /// Minimum 44pt leading-aligned touch target for row-local actions.
    func paydayTouchTarget() -> some View {
        frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}
