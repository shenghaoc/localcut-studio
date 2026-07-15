#if DEBUG
import SwiftUI

/// Narrow harness for XCUI tests of timeline shortcut focus transitions.
/// Pure `TimelineShortcutPolicy` unit tests cover key mapping; this harness
/// exercises whether Space is claimed by a focused text field, button, or the
/// timeline itself.
struct TimelineFocusUITestHarnessView: View {
    @FocusState private var focusedField: Field?
    @State private var lastAction = "none"
    @State private var text = ""

    private enum Field: Hashable {
        case markerName
        case timeline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Timeline Focus Harness")
                .font(.title2)
                .accessibilityIdentifier("uitest-timeline-focus-harness")

            Text(lastAction)
                .accessibilityIdentifier("uitest-last-action")

            TextField("Marker name", text: $text)
                .focused($focusedField, equals: .markerName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("uitest-marker-name-field")
                .onKeyPress(.space) {
                    lastAction = "text-space"
                    return .handled
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "mM")) { press in
                    lastAction = press.modifiers.contains(.shift) ? "text-shift-m" : "text-m"
                    return .handled
                }
                .onKeyPress(.delete) {
                    lastAction = "text-delete"
                    return .handled
                }
                .onKeyPress(.deleteForward) {
                    lastAction = "text-forward-delete"
                    return .handled
                }

            Button("Toggle") {
                lastAction = "button-activate"
            }
            .focused($focusedField, equals: nil)
            .accessibilityIdentifier("uitest-focus-button")
            .onKeyPress(.space) {
                lastAction = "button-space"
                return .handled
            }

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 120)
                .overlay {
                    Text(focusedField == .timeline ? "Timeline focused" : "Timeline idle")
                }
                .focusable()
                .focused($focusedField, equals: .timeline)
                .accessibilityIdentifier("uitest-timeline-region")
                .onTapGesture { focusedField = .timeline }
                .onKeyPress(.space) {
                    guard focusedField == .timeline else { return .ignored }
                    lastAction = "timeline-space"
                    return .handled
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "mM")) { _ in
                    guard focusedField == .timeline else { return .ignored }
                    lastAction = "timeline-m"
                    return .handled
                }

            HStack {
                Button("Focus Text Field") { focusedField = .markerName }
                    .accessibilityIdentifier("uitest-focus-text")
                Button("Focus Timeline") { focusedField = .timeline }
                    .accessibilityIdentifier("uitest-focus-timeline")
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { focusedField = .timeline }
    }
}
#endif
