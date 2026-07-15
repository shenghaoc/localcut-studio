import Foundation
import AVFoundation
import LocalCutCore

@MainActor
final class ImportService {
    func importMedia(urls: [URL], wantsBundling: Bool = true, model: EditorModel) async -> EditorCommandOutcome {
        guard !urls.isEmpty else { return .actionCancelled }
        let generation = model.sessionGeneration
        var loaded: [MediaItem] = []
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            let item = MediaItem(url: url)
            item.wantsBundling = wantsBundling
            do {
                item.duration = try await item.asset.load(.duration).sanitized

                if let videoTrack = try await item.asset.loadTracks(withMediaType: .video).first {
                    item.hasVideo = true
                    item.naturalSize = try await videoTrack.load(.naturalSize).sanitized
                    item.preferredTransform = try await videoTrack.load(.preferredTransform).sanitized
                }
                item.hasAudio = try await !item.asset.loadTracks(withMediaType: .audio).isEmpty

                guard model.sessionGeneration == generation else {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                    return .actionCancelled
                }

                model.retainAccess(url, didStart: didAccess)
                item.bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
                loaded.append(item)
            } catch {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                model.statusMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription). Check that the file is a supported media format and hasn't been moved or deleted."
            }
        }
        guard !loaded.isEmpty else { return .failed }
        guard model.sessionGeneration == generation else { return .actionCancelled }

        let before = model.captureState()
        model.project.mediaItems.append(contentsOf: loaded)
        model.registerImportUndo(name: "Import Media", before: before)
        model.markDirty()
        model.statusMessage = loaded.count == 1
            ? "Imported \(loaded[0].name)."
            : "Imported \(loaded.count) items."
        for item in loaded {
            Task { await item.loadThumbnail() }
        }
        return .completed
    }
}
