import Foundation
import AppKit
import AVFoundation
import CoreMedia
import LocalCutCore

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
            ? try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            : nil
        if let refreshed {
            UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
        }
        return (url, refreshed)
    }
}

extension EditorModel {
    func requestRecorder() {
        isRecorderPresented = true
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
            adoptRecordingsFolderAccess(url)
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
                        microphoneDeviceID: String?) async {
        guard !isRecording, !isStartingRecording, !isStoppingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        guard let root = resolvedRecordingsFolder(promptIfMissing: true) else {
            statusMessage = "Choose a recordings folder before recording."
            return
        }
        let request = CaptureStartRequest(
            target: target,
            includeSystemAudio: includeSystemAudio,
            webcamDeviceID: webcamDeviceID,
            microphoneDeviceID: microphoneDeviceID,
            rootURL: root,
            frameRate: project.frameRate,
            fragmentInterval: CMTime(seconds: 2, preferredTimescale: 600),
            capabilities: Capabilities.current)
        do {
            try await captureCoordinator.start(request, onStreamStopped: { [weak self] error in
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
            })
            recordingStartedAt = Date()
            isRecording = true
            isRecorderPresented = false
            recordingSourceCount = 0
            if target != nil { recordingSourceCount += 1 }
            if includeSystemAudio { recordingSourceCount += 1 }
            if webcamDeviceID != nil { recordingSourceCount += 1 }
            if microphoneDeviceID != nil { recordingSourceCount += 1 }
            recordingBackpressureCount = 0
            recordingDiskFreeBytes = nil
            recordingDiskWarning = nil
            startRecordingMonitor(rootURL: root)
            floatingPanelController.show(model: self)
            try? await captureCoordinator.setFloatingPanelWindowID(floatingPanelController.windowID)
            statusMessage = "Recording…"
        } catch {
            isRecording = false
            recordingStartedAt = nil
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
                self.recordingElapsedSeconds = elapsed
                let now = Date()
                if now.timeIntervalSince(lastDiskCheck) >= 5 {
                    lastDiskCheck = now
                    if let available = try? rootURL.resourceValues(
                        forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                  .volumeTotalCapacityKey])
                        .volumeAvailableCapacityForImportantUsage,
                       let total = try? rootURL.resourceValues(
                        forKeys: [.volumeTotalCapacityKey])
                        .volumeTotalCapacity {
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
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    enum RecordingDiskWarning: Equatable {
        case warn
        case stop
    }

    func stopRecording(statusMessage stopStatusMessage: String = "Stopping recording…") {
        guard isRecording || isPaused, !isStoppingRecording else { return }
        isRecording = false
        isPaused = false
        isStoppingRecording = true
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        floatingPanelController.close()
        statusMessage = stopStatusMessage
        Task {
            defer { isStoppingRecording = false }
            do {
                let result = try await captureCoordinator.stop()
                recordingStartedAt = nil
                recordingElapsedSeconds = 0
                recordingDiskFreeBytes = nil
                recordingDiskWarning = nil
                recordingSourceCount = 0
                recordingBackpressureCount = 0
                let manifestFinalizeFailed = result._manifestFinalizeFailed
                _ = await landCaptureSession(result)
                if manifestFinalizeFailed {
                    statusMessage += " Manifest could not be finalized; this session may be re-offered for recovery on next launch."
                }
            } catch {
                isRecording = false
                recordingStartedAt = nil
                recordingElapsedSeconds = 0
                recordingDiskFreeBytes = nil
                recordingDiskWarning = nil
                recordingSourceCount = 0
                recordingBackpressureCount = 0
                statusMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Phase 42: Countdown

    /// Begin recording after a user-selected countdown delay. The countdown runs
    /// in the UI layer; this method is called when it reaches zero.
    func startRecordingWithCountdown(
        countdownSeconds: Int,
        target: CaptureTarget?,
        includeSystemAudio: Bool,
        webcamDeviceID: String?,
        microphoneDeviceID: String?
    ) async {
        guard !isRecording, !isCountdownActive else { return }
        self.countdownSeconds = countdownSeconds
        isCountdownActive = true
        isRecorderPresented = false

        // Run the countdown. Each second, update the UI; cancellation is handled
        // by the view setting `isCountdownActive = false` or Task cancellation.
        for remaining in (1...countdownSeconds).reversed() {
            guard isCountdownActive else { return }
            statusMessage = "Recording in \(remaining)…"
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                // Task was cancelled (e.g. user dismissed the view). Don't spin
                // to completion — stop the countdown immediately.
                isCountdownActive = false
                return
            }
        }
        guard isCountdownActive else { return }
        isCountdownActive = false

        // Store the request for potential retake.
        lastRecordingRequest = CaptureStartRequest(
            target: target,
            includeSystemAudio: includeSystemAudio,
            webcamDeviceID: webcamDeviceID,
            microphoneDeviceID: microphoneDeviceID,
            rootURL: resolvedRecordingsFolder(promptIfMissing: false)
                ?? FileManager.default.temporaryDirectory,
            frameRate: project.frameRate,
            fragmentInterval: CMTime(seconds: 2, preferredTimescale: 600),
            capabilities: Capabilities.current)
        lastRecordingSlots = []

        await startRecording(
            target: target,
            includeSystemAudio: includeSystemAudio,
            webcamDeviceID: webcamDeviceID,
            microphoneDeviceID: microphoneDeviceID)
    }

    /// Cancel an in-progress countdown before recording starts.
    func cancelCountdown() {
        guard isCountdownActive else { return }
        isCountdownActive = false
        statusMessage = "Countdown cancelled."
    }

    // MARK: - Phase 42: Pause / Resume

    /// Pause the current recording. Stops capture streams and finishes the
    /// current writer chunks. The PTS gap is preserved on the timeline.
    func pauseRecording() async {
        guard isRecording, !isStoppingRecording else { return }
        do {
            try await captureCoordinator.pause()
            isRecording = false
            isPaused = true
            statusMessage = "Recording paused."
        } catch {
            statusMessage = "Could not pause: \(error.localizedDescription)"
        }
    }

    /// Resume a paused recording. Creates new writer chunks and restarts
    /// capture streams. The PTS gap since pause is preserved.
    func resumeRecording() async {
        guard isPaused, !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        do {
            try await captureCoordinator.resume()
            isPaused = false
            isRecording = true
            // Restart the recording monitor (elapsed time, disk space).
            if let root = resolvedRecordingsFolder(promptIfMissing: false) {
                startRecordingMonitor(rootURL: root)
            }
            statusMessage = "Recording…"
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
        // Collect the track IDs that contain recording clips.
        let recordedTrackIDs: Set<UUID> = Set(lastRecordingSlots.map { slot in
            let tracks = slot.trackKind == .video ? project.videoTracks : project.audioTracks
            guard slot.trackIndex < tracks.count else { return slot.clipID }
            return tracks[slot.trackIndex].id
        })
        var collapsed = false
        performUndoable("Collapse Recording Gap") {
            for track in (project.videoTracks + project.audioTracks)
                where recordedTrackIDs.contains(track.id) {
                let sorted = track.clips.sorted { $0.timelineStart < $1.timelineStart }
                guard sorted.count >= 2 else { continue }
                for i in 1..<sorted.count {
                    let prevEnd = sorted[i - 1].timelineStart + sorted[i - 1].duration
                    let gap = sorted[i].timelineStart - prevEnd
                    guard gap > .zero else { continue }
                    if let idx = track.clips.firstIndex(where: { $0.id == sorted[i].id }) {
                        track.clips[idx].timelineStart = prevEnd
                        for j in (idx + 1)..<track.clips.count {
                            track.clips[j].timelineStart = CMTimeMaximum(
                                .zero,
                                track.clips[j].timelineStart - gap)
                        }
                        collapsed = true
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

    // MARK: - Phase 42: Retake

    /// Replace the most recently recorded chunk-set with a fresh recording.
    /// The new recording lands at the same timeline position as the original.
    /// Undoable.
    func retakeRecording() async {
        guard let request = lastRecordingRequest, !isRecording, !isPaused, !isStoppingRecording else {
            statusMessage = "No recording to retake."
            return
        }

        // Store the timeline positions of the clips being removed so the
        // replacement recording lands in the same slots.
        var positions: [UUID: CMTime] = [:]
        for slot in lastRecordingSlots {
            let tracks = slot.trackKind == .video ? project.videoTracks : project.audioTracks
            guard slot.trackIndex < tracks.count else { continue }
            let track = tracks[slot.trackIndex]
            if let clip = track.clips.first(where: { $0.id == slot.clipID }) {
                positions[slot.clipID] = clip.timelineStart
            }
        }
        retakeTimelinePositions = positions

        // Remove the previous recording's tracks/clips.
        if !lastRecordingSlots.isEmpty {
            performUndoable("Retake Recording — Remove Previous") {
                // Remove clips from their tracks, working in reverse to keep
                // indices stable.
                let sortedSlots = lastRecordingSlots.sorted {
                    ($0.trackIndex, $0.clipID.hashValue) > ($1.trackIndex, $1.clipID.hashValue)
                }
                for slot in sortedSlots {
                    let tracks = slot.trackKind == .video ? project.videoTracks : project.audioTracks
                    guard slot.trackIndex < tracks.count else { continue }
                    let track = tracks[slot.trackIndex]
                    if let clipIdx = track.clips.firstIndex(where: { $0.id == slot.clipID }) {
                        track.clips.remove(at: clipIdx)
                    }
                }
                // Remove empty tracks.
                project.videoTracks.removeAll { $0.clips.isEmpty }
                project.audioTracks.removeAll { $0.clips.isEmpty }
                lastRecordingSlots = []
                scheduleRebuild()
            }
        }

        // Start a new recording with the same parameters.
        lastRecordingSlots = []
        await startRecording(
            target: request.target,
            includeSystemAudio: request.includeSystemAudio,
            webcamDeviceID: request.webcamDeviceID,
            microphoneDeviceID: request.microphoneDeviceID)
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

    func importRecoveredCaptureSession(_ result: CaptureSessionResult) {
        Task {
            // Keep the recovery row until landing actually succeeds, so a
            // temporarily unreadable source can be retried instead of vanishing.
            if await landCaptureSession(result) {
                recoveredCaptureSessions.removeAll { $0.id == result.id }
            }
        }
    }

    private struct LoadedCapturedSource {
        var item: MediaItem
        var source: CaptureRecoveredSource
        var didAccess: Bool
    }

    @discardableResult
    func landCaptureSession(_ result: CaptureSessionResult) async -> Bool {
        let recoveredSources = result.manifest.recoveredSources
        guard !recoveredSources.isEmpty else {
            statusMessage = "Recording stopped, but no readable sources were found."
            return false
        }

        // With pause/resume, a single source can produce multiple chunk files
        // (e.g. screen.mov, screen-1.mov). Collect all chunk URLs per source.
        let endedBySource = result.manifest.endedRecordsBySourceID

        var loaded: [LoadedCapturedSource] = []
        var loadErrors: [String] = []
        for source in recoveredSources {
            let chunks = endedBySource[source.id] ?? []
            // Collect (URL, ended-record) pairs for each chunk.
            struct ChunkInfo {
                var url: URL
                var ended: CaptureSourceEndedRecord?
            }
            let chunkInfos: [ChunkInfo]
            if chunks.isEmpty {
                let url = result.directoryURL.appendingPathComponent(source.descriptor.relativePath)
                chunkInfos = FileManager.default.fileExists(atPath: url.path)
                    ? [ChunkInfo(url: url, ended: nil)]
                    : []
            } else {
                chunkInfos = chunks.compactMap { ended -> ChunkInfo? in
                    let resumeCountBefore = result.manifest.records.filter { record in
                        if case .resume(let resume) = record, resume.atUs <= ended.atUs {
                            return true
                        }
                        return false
                    }.count
                    let basePath = source.descriptor.relativePath
                    let baseURL = URL(fileURLWithPath: basePath)
                    let ext = baseURL.pathExtension
                    let stem = baseURL.deletingPathExtension().lastPathComponent
                    let filename = resumeCountBefore == 0
                        ? "\(stem).\(ext)"
                        : "\(stem)-\(resumeCountBefore).\(ext)"
                    let url = result.directoryURL.appendingPathComponent(filename)
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return ChunkInfo(url: url, ended: ended)
                }
            }

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
                    loaded.append(LoadedCapturedSource(item: item, source: chunkSource, didAccess: didAccess))
                } catch {
                    if didAccess { chunk.url.stopAccessingSecurityScopedResource() }
                    loadErrors.append("\(chunk.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        guard !loaded.isEmpty else {
            statusMessage = loadErrors.isEmpty
                ? "Recording stopped, but no captured files could be loaded."
                : "Recording stopped. Sources failed: \(loadErrors.joined(separator: "; "))"
            return false
        }

        var newSlots: [(trackKind: TrackKind, trackIndex: Int, clipID: Clip.ID)] = []
        // If this is a retake landing, use the stored positions.
        let isRetake = !retakeTimelinePositions.isEmpty

        performUndoable(result.wasRecovered ? "Add Recovered Recording" : "Add Recording") {
            project.mediaItems.append(contentsOf: loaded.map(\.item))
            for entry in loaded {
                retainAccess(entry.item.url, didStart: entry.didAccess)
                let duration = entry.item.duration > .zero ? entry.item.duration : entry.source.duration
                guard duration > .zero else { continue }
                // Use retake position if available, otherwise use capture PTS.
                let start: CMTime
                if isRetake, let retakePos = retakeTimelinePositions.values.first {
                    start = retakePos
                } else {
                    start = entry.source.descriptor.timelineStart
                }
                let clip = Clip(
                    mediaID: entry.item.id,
                    sourceStart: .zero,
                    duration: duration,
                    timelineStart: start)
                if entry.item.hasVideo {
                    let track = Track(name: entry.source.descriptor.displayName, kind: .video)
                    track.clips = [clip]
                    project.videoTracks.append(track)
                    newSlots.append((.video, project.videoTracks.count - 1, clip.id))
                }
                if entry.item.hasAudio {
                    let track = Track(name: entry.source.descriptor.displayName, kind: .audio)
                    track.clips = [clip]
                    project.audioTracks.append(track)
                    newSlots.append((.audio, project.audioTracks.count - 1, clip.id))
                }
            }
            statusMessage = result.wasRecovered
                ? "Added recovered recording."
                : "Recording added to timeline."
            scheduleRebuild()
        }

        // Record slots for potential retake.
        if !result.wasRecovered {
            lastRecordingSlots = newSlots
        }
        // Clear retake positions after use.
        retakeTimelinePositions = [:]

        if !loadErrors.isEmpty {
            statusMessage += " Some sources failed: \(loadErrors.joined(separator: "; "))"
        }

        for entry in loaded where entry.item.hasVideo {
            Task { await entry.item.loadThumbnail() }
        }
        return true
    }
}
