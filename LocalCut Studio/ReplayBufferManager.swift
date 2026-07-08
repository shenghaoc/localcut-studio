import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore
import os

/// A finalised replay source ready to be inserted into the timeline.
struct ReplayBufferSavedClip: Hashable, Sendable {
    let url: URL
    let duration: CMTime
    let timelineOffset: CMTime
    let sourceFileURL: URL
    let mediaTypes: Set<EncodedChunkMediaType>

    init(url: URL,
         duration: CMTime,
         timelineOffset: CMTime = .zero,
         sourceFileURL: URL,
         mediaTypes: Set<EncodedChunkMediaType> = []) {
        self.url = url
        self.duration = duration
        self.timelineOffset = timelineOffset
        self.sourceFileURL = sourceFileURL
        self.mediaTypes = mediaTypes
    }

    var hasVideo: Bool { mediaTypes.contains(.video) }
    var hasAudio: Bool { mediaTypes.contains(.audio) }
}

/// Manages the replay buffer lifecycle for a capture session. Owns the
/// `EncodedChunkRing` and coordinates between the capture writer's encoded
/// output and the ring buffer. Provides the "save last N seconds" command.
@MainActor
final class ReplayBufferManager {

    /// The underlying ring buffer.
    let ring: EncodedChunkRing

    /// Current configuration.
    private(set) var config: ReplayBufferConfig

    /// Whether the replay buffer is enabled for this session.
    private(set) var isEnabled: Bool = false

    /// Whether a save is currently in progress.
    private(set) var isSaving: Bool = false

    /// The last saved span's actual duration, for UI display.
    private(set) var lastSavedDuration: Double?
    /// Number of clips written by the last save.
    private(set) var lastSavedClipCount: Int?

    /// The last save error message.
    private(set) var lastSaveError: String?

    /// The session UUID used for spill directory naming.
    private let sessionUUID: UUID

    /// The URL where saved replay clips are written.
    private let savedClipsDirectory: URL
    /// The URL where spilled replay metadata is written.
    private let spillDirectory: URL

    /// Callback to insert saved clips into the timeline.
    private let onClipsSaved: (@MainActor ([ReplayBufferSavedClip]) -> Void)?

    private let log = Logger(
        subsystem: "com.localcutstudio.replay",
        category: "buffer")

    init(sessionUUID: UUID = UUID(),
         config: ReplayBufferConfig = .default,
         onClipsSaved: (@MainActor ([ReplayBufferSavedClip]) -> Void)? = nil) {
        self.sessionUUID = sessionUUID
        self.config = config
        self.onClipsSaved = onClipsSaved

        let caches = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ReplayBuffer", isDirectory: true)
            .appendingPathComponent(sessionUUID.uuidString, isDirectory: true)
        self.savedClipsDirectory = caches.appendingPathComponent("saved", isDirectory: true)
        self.spillDirectory = caches.appendingPathComponent("spill", isDirectory: true)

        self.ring = EncodedChunkRing(config: config, spillDirectory: spillDirectory)
    }

    /// Enables the replay buffer and prepares the saved clips directory.
    func enable() async throws {
        guard !isEnabled else { return }
        try FileManager.default.createDirectory(
            at: savedClipsDirectory,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: spillDirectory,
            withIntermediateDirectories: true)
        isEnabled = true
        log.info("Replay buffer enabled (session \(self.sessionUUID.uuidString))")
    }

    /// Disables the replay buffer and cleans up.
    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        // Don't clear the ring on disable — the session might still be
        // landing. Clear happens on session end.
        log.info("Replay buffer disabled")
    }

    /// Updates the replay buffer configuration.
    func updateConfig(_ newConfig: ReplayBufferConfig) {
        self.config = newConfig
        let ring = self.ring
        Task { await ring.updateConfig(newConfig) }
    }

    /// Appends an encoded chunk to the ring buffer. Called from the capture
    /// writer's fragment tracking.
    func appendChunk(_ chunk: EncodedChunk) {
        guard isEnabled else { return }
        let ring = self.ring
        Task {
            await ring.append(chunk)
        }
    }

    /// "Save last N seconds" command. Finalises the buffered span into a
    /// fragmented `.mov` and triggers timeline insertion.
    func saveLast(seconds: Double) async {
        guard isEnabled else {
            lastSaveError = "Replay buffer is not enabled."
            return
        }
        guard !isSaving else {
            lastSaveError = "A save is already in progress."
            return
        }

        isSaving = true
        lastSaveError = nil
        lastSavedDuration = nil
        lastSavedClipCount = nil

        do {
            let (span, actualSeconds) = await ring.selectSaveSpan(seconds: seconds)
            guard !span.isEmpty else {
                lastSaveError = "No decodable keyframe span available."
                isSaving = false
                return
            }

            let savedClips = try await finalizeSavedClips(from: span)
            let totalDuration = savedClips.reduce(CMTime.zero) { result, clip in
                CMTimeMaximum(result, clip.timelineOffset + clip.duration)
            }
            lastSavedDuration = totalDuration.seconds
            lastSavedClipCount = savedClips.count
            log.info("Saved replay: requested=\(String(format: "%.1f", seconds))s selected=\(String(format: "%.1f", actualSeconds))s written=\(String(format: "%.1f", totalDuration.seconds))s clips=\(savedClips.count)")

            // Trigger timeline insertion.
            onClipsSaved?(savedClips)

        } catch {
            lastSaveError = "Save failed: \(error.localizedDescription)"
            log.error("Replay save failed: \(error.localizedDescription)")
        }

        isSaving = false
    }

    /// Returns current diagnostics.
    func diagnostics() async -> ReplayBufferDiagnostics {
        await ring.diagnostics()
    }

    /// Cleans up replay buffer resources for this session.
    /// Saved clips are preserved since they may be referenced by the timeline.
    func cleanup() async {
        await ring.clear()
    }

    private func finalizeSavedClips(from chunks: [EncodedChunk]) async throws -> [ReplayBufferSavedClip] {
        let globalStart = chunks.map(\.presentationTimeStamp).min() ?? .zero
        let batchID = UUID().uuidString
        let grouped = Dictionary(grouping: chunks, by: \.sourceFileURL)
        var savedClips: [ReplayBufferSavedClip] = []
        var outputURLs: [URL] = []

        do {
            for (index, entry) in grouped.sorted(by: replaySourceSort).enumerated() {
                let outputURL = savedClipsDirectory
                    .appendingPathComponent("replay-\(batchID)-\(index + 1).mov")
                outputURLs.append(outputURL)
                let sourceChunks = entry.value
                let duration = try await ReplayBufferFinalizer.finalize(
                    chunks: sourceChunks,
                    outputURL: outputURL)
                let sourceStart = sourceChunks.map(\.presentationTimeStamp).min() ?? globalStart
                savedClips.append(ReplayBufferSavedClip(
                    url: outputURL,
                    duration: duration,
                    timelineOffset: sourceStart - globalStart,
                    sourceFileURL: entry.key,
                    mediaTypes: Set(sourceChunks.map(\.mediaType))))
            }
        } catch {
            for outputURL in outputURLs {
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw error
        }

        return savedClips
    }

    private func replaySourceSort(_ lhs: (key: URL, value: [EncodedChunk]),
                                  _ rhs: (key: URL, value: [EncodedChunk])) -> Bool {
        let lhsStart = lhs.value.map(\.presentationTimeStamp).min() ?? .zero
        let rhsStart = rhs.value.map(\.presentationTimeStamp).min() ?? .zero
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        let lhsHasVideo = lhs.value.contains { $0.mediaType == .video }
        let rhsHasVideo = rhs.value.contains { $0.mediaType == .video }
        if lhsHasVideo != rhsHasVideo { return lhsHasVideo }
        return lhs.key.path < rhs.key.path
    }
}
