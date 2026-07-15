#if DEBUG
import SwiftUI

/// Hosts the production `TimelineView` with one selected marker so XCUI can
/// verify the real marker-popover focus path without importing media.
struct TimelineViewUITestHarnessView: View {
    @State private var model = EditorModel()
    @State private var didSeedMarker = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Timeline View Harness")
                .accessibilityIdentifier("uitest-real-timeline-harness")
            TimelineView(model: model)
        }
        .onAppear {
            guard !didSeedMarker else { return }
            didSeedMarker = true
            // Keep the marker and its popover away from the window edge where
            // unrelated floating panels can overlap UI-test interactions.
            model.currentTime = 8
            model.addMarkerAtPlayhead()
        }
    }
}
#endif
