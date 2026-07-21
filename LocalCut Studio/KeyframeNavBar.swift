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

    private var previousGuidance: String {
        canGoToPrevious
            ? "Moves the playhead to the previous \(keyframeKind) keyframe."
            : "No earlier \(keyframeKind) keyframe is available."
    }

    private var addOrUpdateGuidance: String {
        let action = hasKeyframeAtPlayhead ? "update" : "add"
        if canAddOrUpdate {
            return "\(action.capitalized)s the \(keyframeKind) keyframe at the playhead."
        }
        return "Move the playhead into the editable range to \(action) a \(keyframeKind) keyframe."
    }

    private var removeGuidance: String {
        canRemove
            ? "Removes the \(keyframeKind) keyframe at the playhead."
            : "No \(keyframeKind) keyframe is at the playhead."
    }

    private var nextGuidance: String {
        canGoToNext
            ? "Moves the playhead to the next \(keyframeKind) keyframe."
            : "No later \(keyframeKind) keyframe is available."
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onPrevious()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help(previousGuidance)
            .accessibilityLabel("Previous \(keyframeKind) keyframe")
            .accessibilityHint(previousGuidance)
            .disabled(!canGoToPrevious)

            Button {
                onAddOrUpdate()
            } label: {
                Label(
                    hasKeyframeAtPlayhead ? "Update" : "Add",
                    systemImage: hasKeyframeAtPlayhead ? "diamond.fill" : "plus.diamond.fill"
                )
                .labelStyle(.iconOnly)
            }
            .disabled(!canAddOrUpdate)
            .help(addOrUpdateGuidance)
            .accessibilityLabel(hasKeyframeAtPlayhead
                                ? "Update \(keyframeKind) keyframe"
                                : "Add \(keyframeKind) keyframe")
            .accessibilityHint(addOrUpdateGuidance)

            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .help(removeGuidance)
            .accessibilityLabel("Remove \(keyframeKind) keyframe")
            .accessibilityHint(removeGuidance)
            .disabled(!canRemove)

            Button {
                onNext()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .help(nextGuidance)
            .accessibilityLabel("Next \(keyframeKind) keyframe")
            .accessibilityHint(nextGuidance)
            .disabled(!canGoToNext)
        }
        .controlSize(.small)
    }
}
