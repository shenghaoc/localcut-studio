import Foundation
import LocalCutCore

/// Focused state container for selection management.
/// Extracted from EditorModel to improve cohesion and testability.
///
/// Selection is mutually exclusive: selecting a clip clears media selection,
/// selecting a marker clears clip selection, etc. This container enforces
/// that invariant through its setter methods.
@Observable
@MainActor
final class SelectionState {
    /// The currently selected clip ID, if any.
    var selectedClipID: Clip.ID?
    /// The currently selected media item ID, if any.
    var selectedMediaID: MediaItem.ID?
    /// The marker currently highlighted on the timeline ruler / inspector.
    var selectedMarkerID: TimelineMarker.ID?
    /// The currently selected overlay clip ID, if any.
    var selectedOverlayID: OverlayClip.ID?
    /// The currently selected callout clip ID, if any.
    var selectedCalloutID: CalloutClip.ID?
    /// The trailing clip whose transition is currently selected, if any.
    var selectedTransitionClipID: Clip.ID?

    // MARK: - Selection methods

    /// Selects a clip, clearing other selections.
    func selectClip(id: Clip.ID?) {
        selectedClipID = id
        selectedMediaID = nil
        selectedMarkerID = nil
        selectedOverlayID = nil
        selectedTransitionClipID = nil
    }

    /// Selects a media item, clearing other selections.
    func selectMedia(id: MediaItem.ID?) {
        selectedMediaID = id
        selectedClipID = nil
        selectedMarkerID = nil
        selectedOverlayID = nil
        selectedTransitionClipID = nil
    }

    /// Selects a marker, clearing other selections.
    func selectMarker(id: TimelineMarker.ID?) {
        selectedMarkerID = id
        selectedClipID = nil
        selectedMediaID = nil
        selectedOverlayID = nil
        selectedTransitionClipID = nil
    }

    /// Selects an overlay, clearing other selections.
    func selectOverlay(id: OverlayClip.ID?) {
        selectedOverlayID = id
        selectedClipID = nil
        selectedMediaID = nil
        selectedMarkerID = nil
        selectedTransitionClipID = nil
    }

    /// Selects a callout, clearing other selections.
    func selectCallout(id: CalloutClip.ID?) {
        selectedCalloutID = id
        selectedClipID = nil
        selectedMediaID = nil
        selectedMarkerID = nil
        selectedOverlayID = nil
        selectedTransitionClipID = nil
    }

    /// Selects a transition, clearing other selections.
    func selectTransition(clipID: Clip.ID?) {
        selectedTransitionClipID = clipID
        selectedClipID = nil
        selectedMediaID = nil
        selectedMarkerID = nil
        selectedOverlayID = nil
    }

    /// Clears all selections.
    func clearAll() {
        selectedClipID = nil
        selectedMediaID = nil
        selectedMarkerID = nil
        selectedOverlayID = nil
        selectedCalloutID = nil
        selectedTransitionClipID = nil
    }
}
