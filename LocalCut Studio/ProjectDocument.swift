import Foundation
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers
import LocalCutCore

// MARK: - Document content type

extension UTType {
    /// The `.lcstudio` project document type. Declared dynamically from the file
    /// extension so no `Info.plist` type declaration is required for the in-app
    /// New/Open/Save lifecycle.
    static let lcStudioProject = UTType(filenameExtension: ProjectDocument.fileExtension,
                                        conformingTo: .data) ?? .data
}

// MARK: - Snapshot (Project → Document)

extension ProjectDocument {
    /// Captures the current arrangement and settings into a document. Media
    /// bookmarks must already be present on each `MediaItem` (created at import);
    /// a media item without a bookmark is stored with empty data and will require
    /// relinking on open.
    init(project: Project) {
        self.init(
            name: project.name,
            renderWidth: Double(project.renderSize.width),
            renderHeight: Double(project.renderSize.height),
            frameRate: project.frameRate,
            workingColourSpace: project.workingColourSpace,
            media: project.mediaItems.map(MediaRef.init(item:)),
            videoTracks: project.videoTracks.map(TrackDoc.init(track:)),
            audioTracks: project.audioTracks.map(TrackDoc.init(track:)),
            captionTracks: project.captionTracks.map(CaptionTrackDoc.init(track:)),
            markers: project.markers,
            audioBus: AudioBusDoc(project: project),
            overlays: project.overlayDocs)
    }

    /// Captures a queue snapshot. Saved bundle documents intentionally strip
    /// bookmarks for bundled overlay assets, but the render queue persists only
    /// the snapshot and not the enclosing bundle URL. When a live bundle project
    /// is queued, add temporary bookmarks for those bundled overlay assets so the
    /// background runner can resolve and render them later.
    init(project: Project, queueBundleURL: URL?) {
        self.init(project: project)
        addQueueOverlayBookmarks(from: queueBundleURL)
    }

    private mutating func addQueueOverlayBookmarks(from bundleURL: URL?) {
        guard let bundleURL,
              ProjectBundle.isBundle(url: bundleURL) else { return }

        let didAccess = bundleURL.startAccessingSecurityScopedResource()
        defer { if didAccess { bundleURL.stopAccessingSecurityScopedResource() } }

        for index in overlays.indices {
            guard overlays[index].bookmark.isEmpty,
                  let relative = overlays[index].bundleRelativePath,
                  ProjectBundleLayout.isSafeAssetRelativePath(relative) else { continue }

            let sourceURL = bundleURL.appendingPathComponent(relative)
            guard FileManager.default.isReadableFile(atPath: sourceURL.path) else { continue }
            overlays[index].bookmark = (try? sourceURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)) ?? Data()
        }
    }
}

extension AudioBusDoc {
    init(project: Project) {
        self.init(
            masterGain: project.masterGain,
            trackInputs: project.trackInputs.map { TrackInputDoc(trackID: $0.id, pan: $0.pan, gain: $0.gain) },
            voiceCleanup: project.voiceCleanup)
    }
}

extension MediaRef {
    init(item: MediaItem) {
        self.init(
            id: item.id,
            displayName: item.name,
            bookmark: item.bookmark ?? Data(),
            duration: CMTimeCode(item.duration),
            naturalWidth: Double(item.naturalSize.width),
            naturalHeight: Double(item.naturalSize.height),
            preferredTransform: TransformCode(item.preferredTransform),
            hasVideo: item.hasVideo,
            hasAudio: item.hasAudio,
            bundleRelativePath: item.bundleRelativePath)
    }
}
