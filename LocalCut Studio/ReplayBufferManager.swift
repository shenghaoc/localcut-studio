import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore
import os

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

    /// The last save error message.
    private(set) var lastSaveError: String?

    /// The session UUID used for spill directory naming.
    private let sessionUUID: UUID

    /// The URL where saved replay clips are written.
    private let savedClipsDirectory: URL

    /// Callback to insert a saved clip into the timeline.
    private let onClipSaved: (@MainActor (URL, CMTime) -> Void)?

    private let log = Logger(
        subsystem: "com.localcutstudio.replay",
        category: "buffer")

    init(sessionUUID: UUID = UUID(),
         config: ReplayBufferConfig = .default,
         onClipSaved: (@MainActor (URL, CMTime) -> Void)? = nil) {
        self.sessionUUID = sessionUUID
        self.config = config
        self.onClipSaved = onClipSaved

        let caches = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ReplayBuffer", isDirectory: true)
            .appendingPathComponent(sessionUUID.uuidString, isDirectory: true)
        self.savedClipsDirectory = caches.appendingPathComponent("saved", isDirectory: true)

        self.ring = EncodedChunkRing(
            config: config,
            spillDirectory: caches.appendingPathComponent("spill", isDirectory: true))
    }

    /// Enables the replay buffer and prepares the spill directory.
    func enable() async throws {
        guard !isEnabled else { return }
        try await ring.prepareSpillDirectory()
        try FileManager.default.createDirectory(
            at: savedClipsDirectory,
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
        Task { await ring.updateConfig(newConfig) }
    }

    /// Appends an encoded chunk to the ring buffer. Called from the capture
    /// writer's fragment tracking.
    func appendChunk(_ chunk: EncodedChunk) {
        guard isEnabled else { return }
        Task {
            await ring.appendWithSpill(chunk)
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

        do {
            let (span, actualSeconds) = await ring.selectSaveSpan(seconds: seconds)
            guard !span.isEmpty else {
                lastSaveError = "No decodable keyframe span available."
                isSaving = false
                return
            }

            // Load all chunks (including spilled) into memory.
            let loaded = await ring.loadChunksForSave(span)
            guard loaded.count == span.count else {
                lastSaveError = "Could not load all chunks for save."
                isSaving = false
                return
            }

            // Finalise into a fragmented .mov.
            let outputURL = savedClipsDirectory
                .appendingPathComponent("replay-\(UUID().uuidString).mov")
            let duration = try await ReplayBufferFinalizer.finalize(
                chunks: loaded,
                outputURL: outputURL)

            lastSavedDuration = duration.seconds
            log.info("Saved replay clip: \(String(format: "%.1f", duration.seconds))s at \(outputURL.lastPathComponent)")

            // Trigger timeline insertion.
            onClipSaved?(outputURL, duration)

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

    /// Cleans up all replay buffer resources for this session.
    func cleanup() async {
        await ring.clear()
        try? FileManager.default.removeItem(at: savedClipsDirectory.deletingLastPathComponent())
    }
}
