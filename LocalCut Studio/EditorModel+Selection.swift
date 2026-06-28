import Foundation
import LocalCutCore

extension EditorModel {
    func selectMedia(id: MediaItem.ID) {
        selectedMediaID = id
        selectedClipID = nil
        selectedTransitionClipID = nil
        selectedMarkerID = nil
        selectedOverlayID = nil
    }

    func selectClip(id: Clip.ID) {
        selectedClipID = id
        selectedMediaID = nil
        selectedTransitionClipID = nil
        selectedMarkerID = nil
        selectedOverlayID = nil
    }

    func selectTransition(clipID: Clip.ID) {
        selectedTransitionClipID = clipID
        selectedClipID = nil
        selectedMediaID = nil
        selectedMarkerID = nil
        selectedOverlayID = nil
    }

    func clearSelection() {
        selectedClipID = nil
        selectedMediaID = nil
        selectedTransitionClipID = nil
        selectedMarkerID = nil
        selectedOverlayID = nil
    }
}
