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
        guard !isRecording else { return }
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
        guard isRecording else { return }
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        statusMessage = stopStatusMessage
        Task {
            do {
                let result = try await captureCoordinator.stop()
                isRecording = false
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

        var loaded: [LoadedCapturedSource] = []
        var loadErrors: [String] = []
        for source in recoveredSources {
            let url = result.directoryURL.appendingPathComponent(source.descriptor.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let didAccess = url.startAccessingSecurityScopedResource()
            let item = MediaItem(url: url)
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
                item.bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil)
                loaded.append(LoadedCapturedSource(item: item, source: source, didAccess: didAccess))
            } catch {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                // Accumulate so a later successful source doesn't overwrite and
                // hide this failure in the status line.
                loadErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        guard !loaded.isEmpty else {
            statusMessage = loadErrors.isEmpty
                ? "Recording stopped, but no captured files could be loaded."
                : "Recording stopped. Sources failed: \(loadErrors.joined(separator: "; "))"
            return false
        }

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
                }
                if entry.item.hasAudio {
                    let track = Track(name: entry.source.descriptor.displayName, kind: .audio)
                    track.clips = [clip]
                    project.audioTracks.append(track)
                }
            }
            statusMessage = result.wasRecovered
                ? "Added recovered recording."
                : "Recording added to timeline."
            scheduleRebuild()
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
