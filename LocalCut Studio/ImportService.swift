import Foundation
import AVFoundation
import LocalCutCore

@MainActor
final class ImportService {
    @MainActor
    func importMedia(urls: [URL], wantsBundling: Bool = true, model: EditorModel) async -> EditorCommandOutcome {
        guard !urls.isEmpty else { return .actionCancelled }
        let generation = model.sessionGeneration
        var loaded: [(item: MediaItem, didAccess: Bool)] = []
        var failureMessages: [String] = []
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

                guard !Task.isCancelled, model.sessionGeneration == generation else {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                    stopPendingAccesses(loaded)
                    return .actionCancelled
                }

                item.bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
                loaded.append((item, didAccess))
            } catch is CancellationError {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                stopPendingAccesses(loaded)
                return .actionCancelled
            } catch {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                let message = EditorModel.failureStatusMessage(
                    summary: "Could not import \(url.lastPathComponent)",
                    detail: error.localizedDescription,
                    recoverySuggestion: "Check that the file is a supported media format and hasn't been moved or deleted.")
                failureMessages.append(message)
            }
        }
        guard !loaded.isEmpty else {
            model.statusMessage = Self.boundedFailureSummary(failureMessages)
            return .failed
        }
        guard !Task.isCancelled, model.sessionGeneration == generation else {
            stopPendingAccesses(loaded)
            return .actionCancelled
        }

        for entry in loaded {
            model.retainAccess(entry.item.url, didStart: entry.didAccess)
        }

        let before = model.captureState()
        model.project.mediaItems.append(contentsOf: loaded.map(\.item))
        model.registerImportUndo(name: "Import Media", before: before)
        model.markDirty()
        let successMessage = loaded.count == 1
            ? "Imported \(loaded[0].item.name)."
            : "Imported \(loaded.count) items."
        model.statusMessage = Self.combinedStatusMessage(
            successMessage: successMessage,
            failureMessages: failureMessages)
        for entry in loaded {
            Task { await entry.item.loadThumbnail() }
        }
        return .completed
    }

    private func stopPendingAccesses(_ entries: [(item: MediaItem, didAccess: Bool)]) {
        for entry in entries where entry.didAccess {
            entry.item.url.stopAccessingSecurityScopedResource()
        }
    }

    nonisolated static func combinedStatusMessage(
        successMessage: String,
        failureMessages: [String]
    ) -> String {
        guard !failureMessages.isEmpty else { return successMessage }
        return "\(successMessage) \(boundedFailureSummary(failureMessages))"
    }

    nonisolated static func boundedFailureSummary(_ failureMessages: [String]) -> String {
        guard let firstFailure = failureMessages.first else {
            return "Could not import the selected media. Try choosing supported files that are still accessible."
        }
        let additionalFailureCount = failureMessages.count - 1
        guard additionalFailureCount > 0 else { return firstFailure }
        return "\(firstFailure) \(additionalFailureCount) more file\(additionalFailureCount == 1 ? "" : "s") could not be imported."
    }
}
