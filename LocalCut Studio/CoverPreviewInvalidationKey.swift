import Foundation
import CoreGraphics
import CoreMedia
import LocalCutCore

@MainActor
enum CoverPreviewInvalidationKey {
    static func make(for project: Project) -> Int {
        var hasher = Hasher()
        hasher.combine(project.frameRate)
        hasher.combine(project.renderSize.width)
        hasher.combine(project.renderSize.height)
        hasher.combine(project.workingColourSpace)
        combineVideoContent(project, into: &hasher)
        combineCaptionContent(project, into: &hasher)
        combineOverlayContent(project, into: &hasher)
        return hasher.finalize()
    }

    private static func combineVideoContent(_ project: Project, into hasher: inout Hasher) {
        for media in project.mediaItems.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(media.id)
            hasher.combine(media.url.path)
            hasher.combine(media.duration.value)
            hasher.combine(media.duration.timescale)
            hasher.combine(media.duration.flags.rawValue)
            hasher.combine(media.naturalSize.width)
            hasher.combine(media.naturalSize.height)
            hasher.combine(media.preferredTransform.a)
            hasher.combine(media.preferredTransform.b)
            hasher.combine(media.preferredTransform.c)
            hasher.combine(media.preferredTransform.d)
            hasher.combine(media.preferredTransform.tx)
            hasher.combine(media.preferredTransform.ty)
            hasher.combine(media.hasVideo)
        }

        for track in project.videoTracks {
            hasher.combine(track.id)
            hasher.combine(track.isMuted)
            hasher.combine(track.clips)
        }
    }

    private static func combineCaptionContent(_ project: Project, into hasher: inout Hasher) {
        for track in project.captionTracks {
            hasher.combine(track.id)
            hasher.combine(track.isMuted)
            hasher.combine(track.defaultStyle)
            hasher.combine(track.lines)
        }
    }

    private static func combineOverlayContent(_ project: Project, into hasher: inout Hasher) {
        hasher.combine(project.overlays)
        for (id, path) in project.overlayBundlePaths.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            hasher.combine(id)
            hasher.combine(path)
        }
        for (id, bookmark) in project.overlayBookmarks.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            hasher.combine(id)
            hasher.combine(bookmark)
        }
    }
}
