import SwiftUI

/// Reusable keyframe navigation bar: previous / add-or-update / remove / next.
/// Used across speed, look, skin-smooth, clip-transform, and callout-transform
/// keyframe editors to avoid duplicating the same four-button HStack.
struct KeyframeNavBar: View {
    let keyframeKind: String
    let canGoToPrevious: Bool
    let canAddOrUpdate: Bool
    let canRemove: Bool
    let canGoToNext: Bool
    let hasKeyframeAtPlayhead: Bool
    let onPrevious: () -> Void
    let onAddOrUpdate: () -> Void
    let onRemove: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onPrevious()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Previous keyframe")
            .accessibilityLabel("Previous \(keyframeKind) keyframe")
            .disabled(!canGoToPrevious)

            Button {
                onAddOrUpdate()
            } label: {
                Label(
                    hasKeyframeAtPlayhead ? "Update" : "Add",
                    systemImage: hasKeyframeAtPlayhead ? "diamond.fill" : "plus.diamond.fill"
                )
            }
            .disabled(!canAddOrUpdate)
            .help(hasKeyframeAtPlayhead
                  ? "Update \(keyframeKind) keyframe"
                  : "Add \(keyframeKind) keyframe")
            .accessibilityLabel(hasKeyframeAtPlayhead
                                ? "Update \(keyframeKind) keyframe"
                                : "Add \(keyframeKind) keyframe")

            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove keyframe")
            .accessibilityLabel("Remove \(keyframeKind) keyframe")
            .disabled(!canRemove)

            Button {
                onNext()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .help("Next keyframe")
            .accessibilityLabel("Next \(keyframeKind) keyframe")
            .disabled(!canGoToNext)
        }
        .controlSize(.small)
    }
}
