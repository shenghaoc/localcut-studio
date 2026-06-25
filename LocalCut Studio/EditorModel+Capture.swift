import Foundation
import AppKit
import AVFoundation
import CoreMedia
import LocalCutCore

private enum RecordingFolderStore {
    static let bookmarkKey = "LocalCutStudio.recordingsFolderBookmark"

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
        if let resolved = try? RecordingFolderStore.resolve() {
            adoptRecordingsFolderAccess(resolved.url)
            return resolved.url
        }
        guard promptIfMissing else { return nil }
        return chooseRecordingsFolder()
    }

    private func adoptRecordingsFolderAccess(_ url: URL) {
        if recordingsFolderAccessURL?.standardizedFileURL == url.standardizedFileURL {
            return
        }
        recordingsFolderAccessURL?.stopAccessingSecurityScopedResource()
        let didStart = url.startAccessingSecurityScopedResource()
        recordingsFolderAccessURL = didStart ? url : nil
    }

    func scanRecoveredRecordings() async {
        guard let root = resolvedRecordingsFolder(promptIfMissing: false) else { return }
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
            try await captureCoordinator.start(request)
            recordingStartedAt = Date()
            isRecording = true
            isRecorderPresented = false
            statusMessage = "Recording…"
        } catch {
            isRecording = false
            recordingStartedAt = nil
            statusMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        statusMessage = "Stopping recording…"
        Task {
            do {
                let result = try await captureCoordinator.stop()
                isRecording = false
                recordingStartedAt = nil
                await landCaptureSession(result)
            } catch {
                isRecording = false
                recordingStartedAt = nil
                statusMessage = error.localizedDescription
            }
        }
    }

    func importRecoveredCaptureSession(_ result: CaptureSessionResult) {
        Task {
            await landCaptureSession(result)
            recoveredCaptureSessions.removeAll { $0.id == result.id }
        }
    }

    private struct LoadedCapturedSource {
        var item: MediaItem
        var source: CaptureRecoveredSource
        var didAccess: Bool
    }

    func landCaptureSession(_ result: CaptureSessionResult) async {
        let recoveredSources = result.manifest.recoveredSources
        guard !recoveredSources.isEmpty else {
            statusMessage = "Recording stopped, but no readable sources were found."
            return
        }

        var loaded: [LoadedCapturedSource] = []
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
                statusMessage = "Could not load \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }

        guard !loaded.isEmpty else {
            statusMessage = "Recording stopped, but no captured files could be loaded."
            return
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

        for entry in loaded where entry.item.hasVideo {
            Task { await entry.item.loadThumbnail() }
        }
    }
}
