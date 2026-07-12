import Foundation
import AppKit
import AVFoundation
import CoreMedia
import LocalCutCore
import LocalCutDomain
import LocalCutPlatform

private enum RecordingFolderStore {
    static let bookmarkKey = "LocalCutStudio.recordingsFolderBookmark"

    static var hasStoredBookmark: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    static func store(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    static func resolve() throws -> (url: URL, refreshedBookmark: Data?)? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
        let refreshed = stale
            ? try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            : nil
        if let refreshed {
            UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
        }
        return (url, refreshed)
    }
}

nonisolated struct RecordingSlotKey: Hashable, Sendable {
    var sourceKind: CaptureSourceKind
    var trackKind: TrackKind
    var chunkIndex: Int
}

nonisolated struct RecordingSlot: Equatable, Sendable {
    var key: RecordingSlotKey
    var trackID: UUID
    var trackIndex: Int
    var clipID: Clip.ID
    var mediaID: UUID
    var timelineStart: CMTime
}

nonisolated struct CaptureLandingChunk: Equatable, Sendable {
    var url: URL
    var ended: CaptureSourceEndedRecord?
    var chunkIndex: Int
}

nonisolated enum CaptureChunkResolver {
    static func chunks(for source: CaptureRecoveredSource,
                       result: CaptureSessionResult,
                       fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [CaptureLandingChunk] {
        let endedRecords = result.manifest.endedRecordsBySourceID[source.id] ?? []
        var chunks = endedRecords.compactMap { ended -> CaptureLandingChunk? in
            let chunkIndex = resumeCount(beforeOrAt: ended.atUs, in: result.manifest)
            let url = chunkURL(
                directoryURL: result.directoryURL,
                baseRelativePath: source.descriptor.relativePath,
                chunkIndex: chunkIndex)
            guard fileExists(url) else { return nil }
            return CaptureLandingChunk(url: url, ended: ended, chunkIndex: chunkIndex)
        }

        if chunks.isEmpty {
            let baseURL = chunkURL(
                directoryURL: result.directoryURL,
                baseRelativePath: source.descriptor.relativePath,
                chunkIndex: 0)
            if fileExists(baseURL) {
                chunks.append(CaptureLandingChunk(url: baseURL, ended: nil, chunkIndex: 0))
            }
        }

        if !result.manifest.isFinalized {
            let openChunkIndex = resumeCount(in: result.manifest)
            let openURL = chunkURL(
                directoryURL: result.directoryURL,
                baseRelativePath: source.descriptor.relativePath,
                chunkIndex: openChunkIndex)
            if fileExists(openURL), !chunks.contains(where: { $0.url == openURL }) {
                chunks.append(CaptureLandingChunk(url: openURL, ended: nil, chunkIndex: openChunkIndex))
            }
        }

        return chunks.sorted { $0.chunkIndex < $1.chunkIndex }
    }

    static func chunkURL(directoryURL: URL, baseRelativePath: String, chunkIndex: Int) -> URL {
        let baseURL = URL(filePath: baseRelativePath)
        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let filename = chunkIndex == 0 ? "\(stem).\(ext)" : "\(stem)-\(chunkIndex).\(ext)"
        return directoryURL.appendingPathComponent(filename)
    }

    private static func resumeCount(in manifest: CaptureManifest) -> Int {
        manifest.records.reduce(0) { count, record in
            if case .resume = record { return count + 1 }
            return count
        }
    }

    private static func resumeCount(beforeOrAt atUs: Int64, in manifest: CaptureManifest) -> Int {
        manifest.records.reduce(0) { count, record in
            if case .resume(let resume) = record, resume.atUs <= atUs {
                return count + 1
            }
            return count
        }
    }
}

extension EditorModel {
    func requestRecorder() {
        isRecorderPresented = true
    }

    var canCollapseRecordingGaps: Bool {
        hasLastRecordingTake && !isRecording && !isPaused && !isStartingRecording && !isPausingRecording && !isStoppingRecording
    }

    var canRetakeRecording: Bool {
        hasLastRecordingTake && lastRecordingRequest != nil && !isRecording && !isPaused && !isStartingRecording && !isPausingRecording && !isStoppingRecording
    }

    func chooseRecordingsFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Recordings Folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try RecordingFolderStore.store(url)
            guard adoptRecordingsFolderAccess(url) else {
                statusMessage = "Could not access recordings folder."
                return nil
            }
            statusMessage = "Recordings folder set to \(url.lastPathComponent)."
            return url
        } catch {
            statusMessage = "Could not store recordings folder access: \(error.localizedDescription)"
            return nil
        }
    }

    func resolvedRecordingsFolder(promptIfMissing: Bool) -> URL? {
        // Only treat the bookmarked folder as usable if security-scoped access
        // was actually acquired; a stale bookmark would otherwise return a URL
        // we cannot write to.
        if let resolved = try? RecordingFolderStore.resolve(), adoptRecordingsFolderAccess(resolved.url) {
            return resolved.url
        }
        guard promptIfMissing else { return nil }
        return chooseRecordingsFolder()
    }

    @discardableResult
    private func adoptRecordingsFolderAccess(_ url: URL) -> Bool {
        if recordingsFolderAccessURL?.standardizedFileURL == url.standardizedFileURL {
            return true
        }
        recordingsFolderAccessURL?.stopAccessingSecurityScopedResource()
        let didStart = url.startAccessingSecurityScopedResource()
        recordingsFolderAccessURL = didStart ? url : nil
        return didStart
    }

    func scanRecoveredRecordings() async {
        guard let root = resolvedRecordingsFolder(promptIfMissing: false) else {
            // A bookmark exists but couldn't be resolved (folder moved, app
            // reinstalled): tell the user how to get recovery back instead of
            // silently showing an empty bin.
            if RecordingFolderStore.hasStoredBookmark {
                statusMessage = "Choose your recordings folder to recover past sessions."
            }
            return
        }
        do {
            recoveredCaptureSessions = try await captureCoordinator.scanRecoveredSessions(rootURL: root)
            if !recoveredCaptureSessions.isEmpty {
                statusMessage = "Recovered \(recoveredCaptureSessions.count) recording session(s)."
            }
        } catch {
            statusMessage = "Could not scan recordings: \(error.localizedDescription)"
        }
    }

    func startRecording(target: CaptureTarget?,
                        includeSystemAudio: Bool,
                        webcamDeviceID: String?,
                        microphoneDeviceID: String?,
                        captureRegion: CaptureRegion? = nil,
                        pipPreset: PiPPreset? = nil) async {
        guard !isRecording, !isPaused, !isCountdownActive, !isStartingRecording, !isPausingRecording, !isStoppingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        guard let root = resolvedRecordingsFolder(promptIfMissing: true) else {
            statusMessage = "Choose a recordings folder before recording."
            return
        }
        let wasRecorderPresented = isRecorderPresented
        isRecorderPresented = false
        floatingPanelController.show(model: self)
        let panelWindowID = floatingPanelController.windowID
        let excludedWindowIDs: Set<CGWindowID> = panelWindowID == 0 ? [] : [panelWindowID]
        audioBus.updateLiveCleanupSettings(project.voiceCleanup)
        let request = CaptureStartRequest(
            target: target,
            includeSystemAudio: includeSystemAudio,
            webcamDeviceID: webcamDeviceID,
            microphoneDeviceID: microphoneDeviceID,
            rootURL: root,
            frameRate: project.frameRate,
            fragmentInterval: CMTime(seconds: 2, preferredTimescale: 600),
            capabilities: Capabilities.current,
            captureRegion: captureRegion,
            excludedWindowIDs: excludedWindowIDs,
            voiceCleanupSettings: audioBus.voiceCleanupSettingsStore)
        lastRecordingRequest = request
        activePiPPreset = pipPreset
        lastRecordingPiPPreset = pipPreset

        // Set up replay buffer if enabled.
        let sessionUUID = UUID()
        var replayManager: ReplayBufferManager?
        if replayBufferEnabled {
            let config = ReplayBufferConfig(
                durationOption: replayBufferDuration)
            let manager = ReplayBufferManager(
                sessionUUID: sessionUUID,
                config: config,
                onClipsSaved: { [weak self] clips in
                    Task { @MainActor in
                        await self?.insertReplayClips(clips)
                    }
                })
            do {
                try await manager.enable()
                replayManager = manager
            } catch {
                statusMessage = "Could not enable replay buffer: \(error.localizedDescription)"
            }
        }
        replayBufferManager = replayManager

        do {
            try await captureCoordinator.start(request, encoderBudget: encoderBudget, onStreamStopped: { [weak self] error in
                // The screen stream ended unexpectedly mid-recording; stop and
                // finalize so the toolbar doesn't keep showing an active capture.
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.stopRecording(statusMessage: "Screen capture stopped: \(error.localizedDescription)")
                }
            }, onBackpressure: { [weak self] source in
                // Sustained frame drops — warn the user so they don't finish with
                // a silently gapped take.
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.recordingBackpressureCount += 1
                    self.statusMessage = "Recording can't keep up — dropping data from \(source.displayName). Free disk space or lower the frame rate."
                }
            }, onMicrophoneLevel: { [weak self] level in
                Task { @MainActor in
                    guard let self, self.isRecording || self.isPaused else { return }
                    self.recordingMicLevel = level
                }
            }, onEncodedChunk: { [weak replayManager] chunk in
                Task { @MainActor in
                    replayManager?.appendChunk(chunk)
                }
            })
            recordingStartedAt = Date()
            recordingPausedDuration = 0
            pauseStartedAt = nil
            isRecording = true
            isRecorderPresented = false
            recordingSourceCount = 0
            if target != nil { recordingSourceCount += 1 }
            if includeSystemAudio { recordingSourceCount += 1 }
            if webcamDeviceID != nil { recordingSourceCount += 1 }
            if microphoneDeviceID != nil { recordingSourceCount += 1 }
            recordingBackpressureCount = 0
            recordingIncludesMicrophone = microphoneDeviceID != nil
            recordingMicLevel = 0
            if includeSystemAudio || microphoneDeviceID != nil {
                let latency = audioBus.measureLiveMonitorLatency(settings: project.voiceCleanup)
                recordingLiveMonitorLatencyMs = latency.totalMilliseconds
            } else {
                recordingLiveMonitorLatencyMs = 0
            }
            diagnostics.updateLiveMonitorLatency(recordingLiveMonitorLatencyMs)
            recordingDiskFreeBytes = nil
            recordingDiskWarning = nil
            startRecordingMonitor(rootURL: root)
            var panelExclusionWarning: String?
            do {
                try await captureCoordinator.setFloatingPanelWindowID(panelWindowID)
            } catch {
                panelExclusionWarning = "Recording started, but floating controls may appear in capture: \(error.localizedDescription)"
            }
            if hideFloatingPanelWhileRecording {
                floatingPanelController.hide()
            }
            let latencySuffix = recordingLiveMonitorLatencyMs > 0
                ? String(format: " Monitor latency %.1f ms.", recordingLiveMonitorLatencyMs)
                : ""
            statusMessage = panelExclusionWarning ?? "Recording…\(latencySuffix)"
        } catch {
            teardownReplayBuffer(replayManager)
            floatingPanelController.close()
            isRecorderPresented = wasRecorderPresented
            activePiPPreset = nil
            isRecording = false
            recordingStartedAt = nil
            recordingIncludesMicrophone = false
            recordingMicLevel = 0
            statusMessage = error.localizedDescription
        }
    }

    private func startRecordingMonitor(rootURL: URL) {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = Task { [weak self] in
            guard let self else { return }
            var lastDiskCheck = Date.distantPast
            while !Task.isCancelled, self.isRecording {
                let elapsed = Date().timeIntervalSince(self.recordingStartedAt ?? Date())
                    - self.recordingPausedDuration
                self.recordingElapsedSeconds = elapsed
                let now = Date()
                if now.timeIntervalSince(lastDiskCheck) >= 5 {
                    lastDiskCheck = now
                    // Move synchronous file I/O off the main actor to avoid
                    // blocking the UI on slow or network-mounted volumes.
                    let diskInfo = await Task.detached {
                        let available = try? rootURL.resourceValues(
                            forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                      .volumeTotalCapacityKey])
                            .volumeAvailableCapacityForImportantUsage
                        let total = try? rootURL.resourceValues(
                            forKeys: [.volumeTotalCapacityKey])
                            .volumeTotalCapacity
                        return (available, total)
                    }.value
                    if let available = diskInfo.0, let total = diskInfo.1 {
                        self.recordingDiskFreeBytes = available
                        let fraction = total > 0 ? Double(available) / Double(total) : 0
                        if fraction < 0.05 {
                            self.recordingDiskWarning = .stop
                            self.stopRecording(statusMessage: "Disk space critically low — stopping recording.")
                        } else if fraction < 0.10 {
                            if self.recordingDiskWarning != .warn {
                                self.statusMessage = "Low disk space — recording will stop at 5% free."
                            }
                            self.recordingDiskWarning = .warn
                        } else {
                            if self.recordingDiskWarning != nil, self.isRecording {
                                self.statusMessage = "Recording…"
                            }
                            self.recordingDiskWarning = nil
                        }
                    }
                }
                // Update replay buffer diagnostics periodically.
                if let replayManager = self.replayBufferManager {
                    let diag = await replayManager.diagnostics()
                    self.diagnostics.updateReplayBufferDiagnostics(
                        diag,
                        latencyMs: self.recordingLiveMonitorLatencyMs)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    enum RecordingDiskWarning: Equatable {
        case warn
        case stop
    }

    func stopRecording(statusMessage stopStatusMessage: String = "Stopping recording…") {
        guard isRecording || isPaused,
              !isStartingRecording,
              !isPausingRecording,
              !isStoppingRecording else {
            return
        }
        isRecording = false
        isPaused = false
        isStoppingRecording = true
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        floatingPanelController.close()
        statusMessage = stopStatusMessage
        Task { [weak self] in
            guard let self else { return }
            defer { self.isStoppingRecording = false }
            do {
                let result = try await self.captureCoordinator.stop()
                self.resetRecordingRuntimeState()
                self.cleanupReplayBuffer()
                let manifestFinalizationError = result.manifestFinalizationError
                _ = await self.landCaptureSession(result)
                if let manifestFinalizationError {
                    self.statusMessage += " Manifest could not be finalized: \(manifestFinalizationError). This session may be re-offered for recovery on next launch."
                }
            } catch {
                self.isRecording = false
                self.isPaused = false
                self.resetRecordingRuntimeState()
                self.statusMessage = error.localizedDescription
            }
        }
    }

    private func resetRecordingRuntimeState() {
        recordingStartedAt = nil
        recordingPausedDuration = 0
        pauseStartedAt = nil
        recordingElapsedSeconds = 0
        recordingDiskFreeBytes = nil
        recordingDiskWarning = nil
        recordingSourceCount = 0
        recordingBackpressureCount = 0
        recordingIncludesMicrophone = false
        recordingMicLevel = 0
        recordingLiveMonitorLatencyMs = 0
        diagnostics.updateLiveMonitorLatency(0)
    }

    // MARK: - Phase 42: Countdown

    /// Begin recording after a user-selected countdown delay.
    func startRecordingWithCountdown(
        countdownSeconds: Int,
        target: CaptureTarget?,
        includeSystemAudio: Bool,
        webcamDeviceID: String?,
        microphoneDeviceID: String?,
        captureRegion: CaptureRegion? = nil,
        pipPreset: PiPPreset? = nil
    ) async {
        guard !isRecording, !isPaused, !isCountdownActive, !isStartingRecording, !isPausingRecording, !isStoppingRecording else { return }
        let countdownSeconds = max(0, countdownSeconds)
        self.countdownSeconds = countdownSeconds
        countdownRemaining = countdownSeconds
        isCountdownActive = true
        isRecorderPresented = false

        for remaining in stride(from: countdownSeconds, through: 1, by: -1) {
            guard isCountdownActive else {
                countdownRemaining = 0
                return
            }
            countdownRemaining = remaining
            statusMessage = "Recording in \(remaining)…"
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                isCountdownActive = false
                countdownRemaining = 0
                return
            }
        }
        guard isCountdownActive else {
            countdownRemaining = 0
            return
        }
        countdownRemaining = 0
        isCountdownActive = false

        lastRecordingSlots = []
        hasLastRecordingTake = false

        await startRecording(
            target: target,
            includeSystemAudio: includeSystemAudio,
            webcamDeviceID: webcamDeviceID,
            microphoneDeviceID: microphoneDeviceID,
            captureRegion: captureRegion,
            pipPreset: pipPreset)
    }

    /// Cancel an in-progress countdown before recording starts.
    func cancelCountdown() {
        guard isCountdownActive else { return }
        isCountdownActive = false
        countdownRemaining = 0
        statusMessage = "Countdown cancelled."
    }

    // MARK: - Phase 42: Pause / Resume

    /// Pause the current recording. Stops capture streams and finishes the
    /// current writer chunks. The PTS gap is preserved on the timeline.
    func pauseRecording() async {
        guard isRecording, !isPausingRecording, !isStoppingRecording else { return }
        isPausingRecording = true
        statusMessage = "Pausing recording…"
        defer { isPausingRecording = false }
        do {
            try await captureCoordinator.pause()
            pauseStartedAt = Date()
            isRecording = false
            isPaused = true
            recordingMicLevel = 0
            statusMessage = "Recording paused."
        } catch {
            if (error as? CaptureEngineError) == .notRecording {
                recordingMonitorTask?.cancel()
                recordingMonitorTask = nil
                isRecording = false
                isPaused = false
                recordingMicLevel = 0
                statusMessage = "Could not pause: \(error.localizedDescription)"
            } else {
                recordingMonitorTask?.cancel()
                recordingMonitorTask = nil
                pauseStartedAt = pauseStartedAt ?? Date()
                isRecording = false
                isPaused = true
                recordingMicLevel = 0
                statusMessage = "Recording paused with errors: \(error.localizedDescription)"
            }
        }
    }

    /// Resume a paused recording. Creates new writer chunks and restarts
    /// capture streams. The PTS gap since pause is preserved.
    func resumeRecording() async {
        guard isPaused, !isStartingRecording, !isPausingRecording, !isStoppingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        do {
            try await captureCoordinator.resume()
            if let pauseStart = pauseStartedAt {
                recordingPausedDuration += Date().timeIntervalSince(pauseStart)
            }
            pauseStartedAt = nil
            isPaused = false
            isRecording = true
            recordingMicLevel = 0
            // Re-exclude the floating panel from the resumed capture session.
            var panelExclusionWarning: String?
            do {
                try await captureCoordinator.setFloatingPanelWindowID(
                    floatingPanelController.windowID)
            } catch {
                panelExclusionWarning = "Recording resumed, but floating controls may appear in capture: \(error.localizedDescription)"
            }
            // Restart the recording monitor (elapsed time, disk space).
            if let root = resolvedRecordingsFolder(promptIfMissing: false) {
                startRecordingMonitor(rootURL: root)
            }
            statusMessage = panelExclusionWarning ?? "Recording…"
        } catch {
            statusMessage = "Could not resume: \(error.localizedDescription)"
        }
    }

    // MARK: - Phase 42: Ripple-collapse gap

    /// Collapse timestamp gaps in the most recent recording's tracks caused by
    /// pause/resume. Only operates on tracks/clips referenced by
    /// `lastRecordingSlots` to avoid disturbing unrelated timeline content.
    func collapseRecordingGap() {
        guard !isRecording, !isPaused else {
            statusMessage = "Stop the recording before collapsing gaps."
            return
        }
        guard !lastRecordingSlots.isEmpty else {
            statusMessage = "No recording gaps to collapse."
            return
        }
        // Group recorded clips by source + track kind so pause/resume chunks
        // for screen, webcam, system audio, and microphone collapse
        // independently without cross-source timeline drift.
        struct CollapseGroupKey: Hashable {
            var sourceKind: CaptureSourceKind
            var trackKind: TrackKind
        }
        let slotsByGroup = Dictionary(grouping: lastRecordingSlots) { slot in
            CollapseGroupKey(
                sourceKind: slot.key.sourceKind,
                trackKind: slot.key.trackKind)
        }
        let recordedClipIDs = Set(lastRecordingSlots.map(\.clipID))
        var collapsed = false
        performUndoable("Collapse Recording Gap") {
            for (group, slots) in slotsByGroup {
                let tracks = group.trackKind == .video ? project.videoTracks : project.audioTracks
                let groupClipIDs = Set(slots.map(\.clipID))
                var allClips: [Clip] = []
                for track in tracks {
                    for clip in track.clips where recordedClipIDs.contains(clip.id) && groupClipIDs.contains(clip.id) {
                        allClips.append(clip)
                    }
                }
                allClips.sort { $0.timelineStart < $1.timelineStart }
                guard allClips.count >= 2 else { continue }

                // Compute accumulated gap across all recorded chunks for this source.
                var nextStart = allClips[0].timelineEnd
                var timelineStartsByClipID: [Clip.ID: CMTime] = [:]
                for clip in allClips.dropFirst() {
                    if clip.timelineStart > nextStart {
                        timelineStartsByClipID[clip.id] = nextStart
                        collapsed = true
                    }
                    let adjustedEnd = (timelineStartsByClipID[clip.id] ?? clip.timelineStart) + clip.duration
                    nextStart = CMTimeMaximum(nextStart, adjustedEnd)
                }

                // Apply the computed positions to the actual tracks.
                guard !timelineStartsByClipID.isEmpty else { continue }
                for track in tracks {
                    for index in track.clips.indices {
                        if let newStart = timelineStartsByClipID[track.clips[index].id] {
                            track.clips[index].timelineStart = newStart
                        }
                    }
                }
            }
            if collapsed {
                statusMessage = "Recording gaps collapsed."
                scheduleRebuild()
            } else {
                statusMessage = "No recording gaps to collapse."
            }
        }
    }

    func currentTrackIndicesBySlot(_ slots: [RecordingSlot]) -> [RecordingSlotKey: Int] {
        var trackIndices: [RecordingSlotKey: Int] = [:]
        for slot in slots {
            switch slot.key.trackKind {
            case .video:
                if let index = project.videoTracks.firstIndex(where: { $0.id == slot.trackID }) {
                    trackIndices[slot.key] = index
                }
            case .audio:
                if let index = project.audioTracks.firstIndex(where: { $0.id == slot.trackID }) {
                    trackIndices[slot.key] = index
                }
            case .layout:
                break // Layout tracks are not recording targets.
            }
        }
        return trackIndices
    }

    // MARK: - Phase 42: Retake

    /// Replace the most recently recorded chunk-set with a fresh recording.
    /// The new recording lands at the same timeline position as the original.
    /// Undoable.
    func retakeRecording() async {
        guard let request = lastRecordingRequest,
              !lastRecordingSlots.isEmpty,
              !isRecording, !isPaused, !isStartingRecording, !isPausingRecording, !isStoppingRecording else {
            statusMessage = "No recording to retake."
            return
        }

        let previousSlots = lastRecordingSlots
        let before = captureState()
        retakeUndoBefore = before
        retakePreviousSlots = previousSlots
        retakeTimelinePositions = Dictionary(
            previousSlots.map { ($0.key, $0.timelineStart) },
            uniquingKeysWith: { first, _ in first })
        retakeTrackIndices = currentTrackIndicesBySlot(previousSlots)

        let videoTrackIDs = Set(previousSlots.filter { $0.key.trackKind == .video }.map(\.trackID))
        let audioTrackIDs = Set(previousSlots.filter { $0.key.trackKind == .audio }.map(\.trackID))
        for slot in previousSlots {
            switch slot.key.trackKind {
            case .video:
                guard let trackIndex = project.videoTracks.firstIndex(where: { $0.id == slot.trackID }) else { continue }
                project.videoTracks[trackIndex].clips.removeAll { $0.id == slot.clipID }
            case .audio:
                guard let trackIndex = project.audioTracks.firstIndex(where: { $0.id == slot.trackID }) else { continue }
                project.audioTracks[trackIndex].clips.removeAll { $0.id == slot.clipID }
            case .layout:
                break // Layout tracks are not recording targets.
            }
        }
        project.videoTracks.removeAll { videoTrackIDs.contains($0.id) && $0.clips.isEmpty }
        project.audioTracks.removeAll { audioTrackIDs.contains($0.id) && $0.clips.isEmpty }
        lastRecordingSlots = []
        hasLastRecordingTake = false
        scheduleRebuild()

        // Start a new recording with the same parameters.
        await startRecording(
            target: request.target,
            includeSystemAudio: request.includeSystemAudio,
            webcamDeviceID: request.webcamDeviceID,
            microphoneDeviceID: request.microphoneDeviceID,
            captureRegion: request.captureRegion,
            pipPreset: lastRecordingPiPPreset)
        // If the recording failed to start, clear stale positions so the next
        // normal recording is not corrupted.
        if !isRecording {
            let failureStatus = statusMessage
            applyState(before)
            lastRecordingSlots = previousSlots
            hasLastRecordingTake = !previousSlots.isEmpty
            retakeUndoBefore = nil
            retakePreviousSlots = []
            retakeTimelinePositions = [:]
            retakeTrackIndices = [:]
            scheduleRebuild()
            statusMessage = failureStatus
        }
    }

    // MARK: - Phase 42: Source switching

    /// Switch the screen capture source mid-session. The writer canvas stays
    /// fixed at the original dimensions; the new source's frames are scaled to
    /// fit. The first frame after switch is dropped.
    func switchCaptureSource(to newTarget: CaptureTarget) async {
        guard isRecording else { return }
        do {
            try await captureCoordinator.updateSource(newTarget)
            statusMessage = "Switched to \(newTarget.displayName)."
        } catch {
            statusMessage = "Could not switch source: \(error.localizedDescription)"
        }
    }

    /// Lands a recovered Program Mode session using `ProgramRecovery` to
    /// reconstruct layout clips from the manifest's scene-switch records.
    @discardableResult
    private func landProgramRecovery(_ result: CaptureSessionResult) -> Bool {
        guard let root = resolvedRecordingsFolder(promptIfMissing: false) else {
            statusMessage = "Cannot recover Program Mode session: recordings folder missing."
            return false
        }
        guard let recovery = ProgramRecovery.recover(from: result, rootURL: root) else {
            statusMessage = "Program Mode recovery produced no usable data."
            return false
        }
        // Build a ProgramSessionResult for ProgramLanding.land().
        let programResult = ProgramSessionResult(
            sessionID: recovery.sessionResult.id,
            sessionURL: recovery.sessionResult.directoryURL,
            manifest: recovery.sessionResult.manifest,
            isoTrackURLs: recovery.isoTrackURLs,
            duration: recovery.duration,
            sceneSwitches: recovery.sessionResult.manifest.resolvedSceneSwitches,
            writerWarnings: recovery.issues.map { $0.localizedDescription })
        ProgramLanding.land(result: programResult, model: self)
        if recovery.issues.isEmpty {
            statusMessage = "Recovered Program Mode session landed."
        } else {
            statusMessage = "Recovered with \(recovery.issues.count) issue(s)."
        }
        return true
    }

    func importRecoveredCaptureSession(_ result: CaptureSessionResult) {
        Task { [weak self] in
            guard let self else { return }
            // Keep the recovery row until landing actually succeeds, so a
            // temporarily unreadable source can be retried instead of vanishing.
            if ProgramRecovery.hasProgramData(manifest: result.manifest) {
                if landProgramRecovery(result) {
                    recoveredCaptureSessions.removeAll { $0.id == result.id }
                }
            } else if await landCaptureSession(result) {
                recoveredCaptureSessions.removeAll { $0.id == result.id }
            }
        }
    }

    private struct LoadedCapturedSource {
        var item: MediaItem
        var source: CaptureRecoveredSource
        var chunkIndex: Int
        var didAccess: Bool
    }

    @discardableResult
    func landCaptureSession(_ result: CaptureSessionResult) async -> Bool {
        let landingPiPPreset = result.wasRecovered ? nil : activePiPPreset
        defer {
            if !result.wasRecovered {
                activePiPPreset = nil
            }
        }

        func restoreFailedRetake(status: String) {
            if let before = retakeUndoBefore {
                applyState(before)
                lastRecordingSlots = retakePreviousSlots
                hasLastRecordingTake = !retakePreviousSlots.isEmpty
                retakeUndoBefore = nil
                retakePreviousSlots = []
                retakeTimelinePositions = [:]
                retakeTrackIndices = [:]
                scheduleRebuild()
            }
            statusMessage = status
        }

        let recoveredSources = result.manifest.recoveredSources
        guard !recoveredSources.isEmpty else {
            restoreFailedRetake(status: "Recording stopped, but no readable sources were found.")
            return false
        }

        var loaded: [LoadedCapturedSource] = []
        var loadErrors: [String] = []
        for source in recoveredSources {
            let chunkInfos = CaptureChunkResolver.chunks(for: source, result: result)

            guard !chunkInfos.isEmpty else { continue }

            // Create a MediaItem + LoadedCapturedSource for each chunk so each
            // lands at its own timeline position.
            for (index, chunk) in chunkInfos.enumerated() {
                let didAccess = chunk.url.startAccessingSecurityScopedResource()
                let item = MediaItem(url: chunk.url)
                let chunkLabel = chunkInfos.count > 1 ? " (chunk \(index + 1))" : ""
                item.name = result.wasRecovered
                    ? "Recovered \(source.descriptor.displayName)\(chunkLabel)"
                    : "Recording \(source.descriptor.displayName)\(chunkLabel)"
                item.wantsBundling = true
                do {
                    item.duration = try await item.asset.load(.duration).sanitized
                    if item.duration <= .zero {
                        item.duration = chunk.ended?.duration ?? source.duration
                    }
                    if let videoTrack = try await item.asset.loadTracks(withMediaType: .video).first {
                        item.hasVideo = true
                        item.naturalSize = try await videoTrack.load(.naturalSize).sanitized
                        item.preferredTransform = try await videoTrack.load(.preferredTransform).sanitized
                    }
                    item.hasAudio = try await !item.asset.loadTracks(withMediaType: .audio).isEmpty
                    item.bookmark = try? chunk.url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                    // Build a per-chunk source descriptor with the correct
                    // timelineStart from the ended record.
                    var chunkSource = source
                    if let ended = chunk.ended {
                        chunkSource.descriptor.timelineStartUs = ended.timelineStartUs
                    }
                    loaded.append(LoadedCapturedSource(
                        item: item,
                        source: chunkSource,
                        chunkIndex: chunk.chunkIndex,
                        didAccess: didAccess))
                } catch {
                    if didAccess { chunk.url.stopAccessingSecurityScopedResource() }
                    loadErrors.append("\(chunk.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        guard !loaded.isEmpty else {
            restoreFailedRetake(status: loadErrors.isEmpty
                ? "Recording stopped, but no captured files could be loaded."
                : "Recording stopped. Sources failed: \(loadErrors.joined(separator: "; "))")
            return false
        }

        var newSlots: [RecordingSlot] = []
        let isRetake = !retakeTimelinePositions.isEmpty
        let recordingUndoBefore = isRetake
            ? RecordingUndoState(
                lastRecordingSlots: retakePreviousSlots,
                hasLastRecordingTake: !retakePreviousSlots.isEmpty,
                lastRecordingPiPPreset: lastRecordingPiPPreset)
            : captureRecordingUndoState()

        func slotKey(for entry: LoadedCapturedSource, trackKind: TrackKind) -> RecordingSlotKey {
            RecordingSlotKey(
                sourceKind: entry.source.descriptor.kind,
                trackKind: trackKind,
                chunkIndex: entry.chunkIndex)
        }

        func landingStart(for entry: LoadedCapturedSource, trackKind: TrackKind) -> CMTime {
            let key = slotKey(for: entry, trackKind: trackKind)
            return retakeTimelinePositions[key] ?? entry.source.descriptor.timelineStart
        }

        func clipGeometry(for entry: LoadedCapturedSource) -> ClipGeometry {
            guard entry.source.descriptor.kind == .webcam,
                  let preset = landingPiPPreset else {
                return .identity
            }
            return preset.clipGeometry(canvasSize: project.renderSize,
                                       sourceSize: entry.item.naturalSize)
        }

        let addRecording = { [self] in
            project.mediaItems.append(contentsOf: loaded.map(\.item))
            for entry in loaded {
                retainAccess(entry.item.url, didStart: entry.didAccess)
                let duration = entry.item.duration > .zero ? entry.item.duration : entry.source.duration
                guard duration > .zero else { continue }
                if entry.item.hasVideo {
                    let key = slotKey(for: entry, trackKind: .video)
                    let clip = Clip(
                        mediaID: entry.item.id,
                        sourceStart: .zero,
                        duration: duration,
                        timelineStart: landingStart(for: entry, trackKind: .video),
                        geometry: clipGeometry(for: entry))
                    let track = Track(name: entry.source.descriptor.displayName, kind: .video)
                    track.clips = [clip]
                    // For retakes, insert at the original track index to preserve
                    // z-order; otherwise append.
                    let trackIndex: Int
                    if isRetake, let retakeIdx = retakeTrackIndices[key] {
                        let insertIdx = min(retakeIdx, project.videoTracks.count)
                        project.videoTracks.insert(track, at: insertIdx)
                        trackIndex = insertIdx
                    } else {
                        project.videoTracks.append(track)
                        trackIndex = project.videoTracks.count - 1
                    }
                    newSlots.append(RecordingSlot(
                        key: key,
                        trackID: track.id,
                        trackIndex: trackIndex,
                        clipID: clip.id,
                        mediaID: entry.item.id,
                        timelineStart: clip.timelineStart))
                }
                if entry.item.hasAudio {
                    let key = slotKey(for: entry, trackKind: .audio)
                    let clip = Clip(
                        mediaID: entry.item.id,
                        sourceStart: .zero,
                        duration: duration,
                        timelineStart: landingStart(for: entry, trackKind: .audio))
                    let track = Track(name: entry.source.descriptor.displayName, kind: .audio)
                    track.clips = [clip]
                    let audioTrackIndex: Int
                    if isRetake, let retakeIdx = retakeTrackIndices[key] {
                        let insertIdx = min(retakeIdx, project.audioTracks.count)
                        project.audioTracks.insert(track, at: insertIdx)
                        audioTrackIndex = insertIdx
                    } else {
                        project.audioTracks.append(track)
                        audioTrackIndex = project.audioTracks.count - 1
                    }
                    newSlots.append(RecordingSlot(
                        key: key,
                        trackID: track.id,
                        trackIndex: audioTrackIndex,
                        clipID: clip.id,
                        mediaID: entry.item.id,
                        timelineStart: clip.timelineStart))
                }
            }
            statusMessage = result.wasRecovered
                ? "Added recovered recording."
                : isRetake ? "Retake added to timeline." : "Recording added to timeline."
            scheduleRebuild()
        }

        let projectUndoBefore = retakeUndoBefore ?? captureState()
        invalidateLoudnessMeasurement()
        addRecording()

        // Record slots for potential retake before registering undo, so undo and
        // redo keep the recorder metadata aligned with the restored timeline.
        if !result.wasRecovered {
            lastRecordingSlots = newSlots
            hasLastRecordingTake = !newSlots.isEmpty
            lastRecordingPiPPreset = landingPiPPreset
        }

        let actionName = result.wasRecovered
            ? "Add Recovered Recording"
            : isRetake ? "Retake Recording" : "Add Recording"
        if registerRecordingImportUndo(
            name: actionName,
            before: projectUndoBefore,
            beforeRecording: recordingUndoBefore) {
            markDirty()
        }

        // Clear retake state and PiP preset after use so stale values don't
        // affect future recovered-session imports.
        retakeTimelinePositions = [:]
        retakeTrackIndices = [:]
        retakeUndoBefore = nil
        retakePreviousSlots = []

        if !loadErrors.isEmpty {
            statusMessage += " Some sources failed: \(loadErrors.joined(separator: "; "))"
        }

        // Load event log sidecar if present (Phase 43). Clear stale proposals
        // from a previous capture when no valid log is available.
        let eventsURL = result.directoryURL.appendingPathComponent("events.json")
        if let data = try? Data(contentsOf: eventsURL),
           let log = try? JSONDecoder().decode(ScreencastEventLog.self, from: data),
           log.isSupportedSchema {
            storeScreencastEventLog(log)
            let canvasSize = project.renderSize
            autoZoomProposals = AutoZoomProposalGenerator.generateProposals(
                from: log, canvasSize: canvasSize)
            if !autoZoomProposals.isEmpty {
                statusMessage += " \(autoZoomProposals.count) auto-zoom proposals available."
            }
        } else {
            autoZoomProposals = []
        }

        for entry in loaded where entry.item.hasVideo {
            Task { await entry.item.loadThumbnail() }
        }
        return true
    }

    // MARK: - Replay buffer (Phase 46)

    /// Saves the last N seconds from the replay buffer.
    func saveReplayBuffer(seconds: Double? = nil) {
        let saveSeconds = seconds ?? Double(replayBufferDuration.rawValue)
        guard let manager = replayBufferManager else {
            statusMessage = "Replay buffer is not active."
            return
        }
        guard !replaySaveInProgress else {
            statusMessage = "A replay save is already in progress."
            return
        }

        replaySaveInProgress = true

        Task { [weak self] in
            await manager.saveLast(seconds: saveSeconds)
            self?.replaySaveInProgress = false
            if let error = manager.lastSaveError {
                self?.statusMessage = error
            } else if let duration = manager.lastSavedDuration {
                let clipCount = manager.lastSavedClipCount ?? 1
                self?.statusMessage = clipCount == 1
                    ? String(format: "Saved %.1fs replay clip.", duration)
                    : String(format: "Saved %d replay clips spanning %.1fs.", clipCount, duration)
            }
        }
    }

    /// Cleans up replay buffer resources on session end.
    func cleanupReplayBuffer() {
        teardownReplayBuffer(replayBufferManager)
    }

    /// Releases an enabled replay manager without delaying recorder UI state.
    func teardownReplayBuffer(_ manager: ReplayBufferManager?) {
        guard let manager else { return }
        if replayBufferManager === manager {
            replayBufferManager = nil
        }
        manager.disable()
        Task {
            await manager.cleanup()
        }
    }
}
