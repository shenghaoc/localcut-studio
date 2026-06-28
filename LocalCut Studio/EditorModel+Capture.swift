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
            await captureCoordinator.setFloatingPanelWindowID(floatingPanelController.windowID)
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
        // by the view setting `isCountdownActive = false`.
        for remaining in (1...countdownSeconds).reversed() {
            guard isCountdownActive else { return }
            statusMessage = "Recording in \(remaining)…"
            try? await Task.sleep(for: .seconds(1))
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
            statusMessage = "Recording…"
        } catch {
            statusMessage = "Could not resume: \(error.localizedDescription)"
        }
    }

    // MARK: - Phase 42: Ripple-collapse gap

    /// Collapse timestamp gaps in recording tracks caused by pause/resume.
    /// After a pause/resume cycle, the captured clips land at their raw PTS
    /// positions, leaving gaps on the timeline. This command ripple-closes
    /// those gaps by shifting downstream clips.
    func collapseRecordingGap() {
        guard !isRecording, !isPaused else {
            statusMessage = "Stop the recording before collapsing gaps."
            return
        }
        var collapsed = false
        performUndoable("Collapse Recording Gap") {
            for track in project.videoTracks + project.audioTracks {
                let sorted = track.clips.sorted { $0.timelineStart < $1.timelineStart }
                guard sorted.count >= 2 else { continue }
                for i in 1..<sorted.count {
                    let prevEnd = sorted[i - 1].timelineStart + sorted[i - 1].duration
                    let gap = sorted[i].timelineStart - prevEnd
                    guard gap > .zero else { continue }
                    // Shift this clip and all downstream by -gap.
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

        // Remove the previous recording's tracks/clips.
        if !lastRecordingSlots.isEmpty {
            performUndoable("Retake Recording — Remove Previous") {
                // Remove clips from their tracks, working in reverse to keep
                // indices stable.
                let sortedSlots = lastRecordingSlots.sorted {
                    ($0.trackIndex, $0.clipID.hashValue) > ($1.trackIndex, $1.clipID.hashValue)
                }
                var modifiedTracks: Set<String> = []
                for slot in sortedSlots {
                    let tracks = slot.trackKind == .video ? project.videoTracks : project.audioTracks
                    guard slot.trackIndex < tracks.count else { continue }
                    let track = tracks[slot.trackIndex]
                    if let clipIdx = track.clips.firstIndex(where: { $0.id == slot.clipID }) {
                        track.clips.remove(at: clipIdx)
                        modifiedTracks.insert("\(slot.trackKind)-\(slot.trackIndex)")
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
            // Collect all chunk file URLs for this source.
            let chunkURLs: [URL]
            if chunks.isEmpty {
                // No ended records (recovered / header-only): use the descriptor path.
                let url = result.directoryURL.appendingPathComponent(source.descriptor.relativePath)
                chunkURLs = FileManager.default.fileExists(atPath: url.path) ? [url] : []
            } else {
                chunkURLs = chunks.map { ended in
                    // Reconstruct the relative path from the header source + chunk index.
                    // The ended record doesn't store the path; infer it from the source's
                    // base name. For chunk 0 the file is the original name; for chunks
                    // 1+ it's "base-N.ext".
                    let basePath = source.descriptor.relativePath
                    let baseURL = URL(fileURLWithPath: basePath)
                    let ext = baseURL.pathExtension
                    let stem = baseURL.deletingPathExtension().lastPathComponent
                    // Find the chunk index by matching the ended record's position.
                    let chunkIndex = chunks.firstIndex(where: { $0.sourceID == ended.sourceID && $0.atUs == ended.atUs }) ?? 0
                    let filename = chunkIndex == 0 ? "\(stem).\(ext)" : "\(stem)-\(chunkIndex).\(ext)"
                    return result.directoryURL.appendingPathComponent(filename)
                }.filter { FileManager.default.fileExists(atPath: $0.path) }
            }

            guard !chunkURLs.isEmpty else { continue }

            // Load the first chunk as the primary item.
            let primaryURL = chunkURLs[0]
            let didAccess = primaryURL.startAccessingSecurityScopedResource()
            let item = MediaItem(url: primaryURL)
            item.name = result.wasRecovered
                ? "Recovered \(source.descriptor.displayName)"
                : "Recording \(source.descriptor.displayName)"
            item.wantsBundling = true
            do {
                item.duration = try await item.asset.load(.duration).sanitized
                if item.duration <= .zero, source.duration > .zero {
                    item.duration = source.duration
                }
                if let videoTrack = try await item.asset.loadTracks(withMediaType: .video).first {
                    item.hasVideo = true
                    item.naturalSize = try await videoTrack.load(.naturalSize).sanitized
                    item.preferredTransform = try await videoTrack.load(.preferredTransform).sanitized
                }
                item.hasAudio = try await !item.asset.loadTracks(withMediaType: .audio).isEmpty
                item.bookmark = try? primaryURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil)
                loaded.append(LoadedCapturedSource(item: item, source: source, didAccess: didAccess))
            } catch {
                if didAccess { primaryURL.stopAccessingSecurityScopedResource() }
                loadErrors.append("\(primaryURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        guard !loaded.isEmpty else {
            statusMessage = loadErrors.isEmpty
                ? "Recording stopped, but no captured files could be loaded."
                : "Recording stopped. Sources failed: \(loadErrors.joined(separator: "; "))"
            return false
        }

        var newSlots: [(trackKind: TrackKind, trackIndex: Int, clipID: Clip.ID)] = []

        performUndoable(result.wasRecovered ? "Add Recovered Recording" : "Add Recording") {
            project.mediaItems.append(contentsOf: loaded.map(\.item))
            for entry in loaded {
                retainAccess(entry.item.url, didStart: entry.didAccess)
                let duration = entry.item.duration > .zero ? entry.item.duration : entry.source.duration
                guard duration > .zero else { continue }
                let start = entry.source.descriptor.timelineStart
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

        if !loadErrors.isEmpty {
            statusMessage += " Some sources failed: \(loadErrors.joined(separator: "; "))"
        }

        for entry in loaded where entry.item.hasVideo {
            Task { await entry.item.loadThumbnail() }
        }
        return true
    }
}
