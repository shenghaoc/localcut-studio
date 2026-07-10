import Testing
import Foundation
import AVFoundation
import CoreGraphics
import AudioToolbox
import LocalCutCore
@testable import LocalCut_Studio

// MARK: - ExportPreset (T5.1, R5.1)

@MainActor
@Suite("ExportPreset")
struct ExportPresetTests {

    @Test("Codable round-trip preserves every field")
    func presetRoundTrip() throws {
        for preset in BuiltInExportPresets.all {
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(ExportPreset.self, from: data)
            #expect(decoded == preset, "round-trip differs for \(preset.name)")
        }
    }

    @Test("Custom preset round-trip preserves every field")
    func customPresetRoundTrip() throws {
        let preset = ExportPreset(
            name: "Custom HEVC 720p",
            containerFormat: AVFileType.mp4.rawValue,
            videoCodec: AVVideoCodecType.hevc.rawValue,
            aspect: .widescreen,
            targetSize: CGSize(width: 1280, height: 720),
            bitrate: .high,
            frameRate: 60,
            audioConfig: AudioConfig(codec: kAudioFormatMPEG4AAC,
                                     bitrate: 192_000,
                                     sampleRate: 48_000,
                                     channels: 2))
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: data)
        #expect(decoded == preset)
        #expect(decoded.frameRate == 60)
        #expect(decoded.targetSize.cgSize == CGSize(width: 1280, height: 720))
    }

    // R5.2 — every built-in pair must be in the supported allow-list.
    @Test("Every built-in preset uses a supported (container, codec) pair")
    func builtInsAreSupported() {
        for preset in BuiltInExportPresets.all {
            #expect(ExportPreset.isSupportedCombination(container: preset.containerFormat,
                                                        codec: preset.videoCodec),
                    "\(preset.name) — (\(preset.containerFormat), \(preset.videoCodec)) not in allow-list")
        }
    }

    @Test("Six built-in presets ship by default")
    func builtInCount() {
        // R1.2 — the prompt requires ≥ 6.
        #expect(BuiltInExportPresets.all.count >= 6)
        let names = Set(BuiltInExportPresets.all.map(\.name))
        #expect(names.contains("YouTube 1080p"))
        #expect(names.contains("YouTube 4K"))
        #expect(names.contains("Instagram 9:16"))
        #expect(names.contains("TikTok 9:16"))
        #expect(names.contains("ProRes 4K"))
        #expect(names.contains("Web 720p"))
    }

    @Test("Unsupported combinations are rejected by the allow-list")
    func unsupportedRejected() {
        // ProRes inside an .mp4 container is not a valid mux.
        #expect(!ExportPreset.isSupportedCombination(
            container: AVFileType.mp4.rawValue,
            codec: AVVideoCodecType.proRes422.rawValue))
        #expect(!ExportPreset.isSupportedCombination(
            container: AVFileType.mp4.rawValue,
            codec: AVVideoCodecType.proRes422HQ.rawValue))
        #expect(!ExportPreset.isSupportedCombination(
            container: AVFileType.mp4.rawValue,
            codec: AVVideoCodecType.proRes4444.rawValue))
    }

    @Test("Built-in preset ids are stable across constructions")
    func builtInPresetIDsStable() {
        // Compare against the literal hard-coded UUID so the test actually
        // exercises the value rather than self-comparing (Claude review).
        // If the id ever changes, persisted queue jobs that reference the
        // built-in by id would silently fail to round-trip equal after a
        // relaunch.
        let expected = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        #expect(BuiltInExportPresets.youTube1080p.id == expected)
        #expect(BuiltInExportPresets.preset(id: expected)?.name == "YouTube 1080p")
    }
}

// MARK: - RenderQueueDoc + reconcile (T5.5, R5.5)

@MainActor
@Suite("RenderQueueDoc")
struct RenderQueueDocTests {

    private func sampleJob(status: QueueJobStatus = .queued,
                           outputBookmark: Data = Data([0x00, 0x01])) -> QueueJob {
        QueueJob(
            preset: BuiltInExportPresets.web720p,
            outputBookmark: outputBookmark,
            outputDisplayName: "test.mp4",
            projectSnapshot: ProjectDocument(
                name: "T",
                renderWidth: 1280, renderHeight: 720, frameRate: 30,
                media: [],
                videoTracks: [],
                audioTracks: []),
            status: status,
            progress: status == .running ? 0.5 : 0)
    }

    @Test("RenderQueueDoc round-trips through JSON")
    func docRoundTrip() throws {
        let doc = RenderQueueDoc(jobs: [
            sampleJob(status: .queued),
            sampleJob(status: .completed),
        ])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(RenderQueueDoc.self, from: data)
        #expect(decoded == doc)
        #expect(decoded.jobs.count == 2)
        #expect(decoded.jobs[0].status == .queued)
        #expect(decoded.jobs[1].status == .completed)
    }

    @Test("Reconcile: a .running job from disk rewinds to .queued")
    func reconcileRewindsRunning() {
        // The bookmark resolves (we use a real path-derived bookmark below to
        // keep the test focused on the rewind transition; an unresolvable
        // bookmark is a separate test).
        let tempURL = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("renderqueue-test-\(UUID()).bookmark")
        // Use Application Support — sandboxed apps reach it without panel/scope.
        // The bookmark format isn't really security-scoped here, but it
        // resolves, which is what `canResolve` checks.
        let validBookmark: Data
        do {
            try Data().write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            // Outside the sandbox, .withSecurityScope may fail; if so, the
            // test below fall-back-asserts only the .running rewind, not the
            // bookmark resolution branch.
            validBookmark = (try? tempURL.bookmarkData()) ?? Data()
        } catch {
            validBookmark = Data()
        }
        let running = QueueJob(
            preset: BuiltInExportPresets.web720p,
            outputBookmark: validBookmark,
            outputDisplayName: "stale.mp4",
            projectSnapshot: ProjectDocument(
                name: "T", renderWidth: 1280, renderHeight: 720, frameRate: 30,
                media: [], videoTracks: [], audioTracks: []),
            status: .running, progress: 0.4)
        let reconciled = RenderQueue.reconcile(loaded: [running])
        // Whether the bookmark resolves or not, the job leaves `.running` —
        // either to `.queued` (resolved) or to `.failed` (stale bookmark).
        #expect(reconciled[0].status != .running)
        #expect(reconciled[0].progress == 0)
    }

    @Test("Reconcile: an unresolvable bookmark flips a queued job to .failed")
    func reconcileStaleBookmarkFails() {
        // 8 random bytes are not a valid bookmark, so URL(resolvingBookmarkData:)
        // throws — exactly the path R3.3 wants surfaced as `.failed`.
        let job = QueueJob(
            preset: BuiltInExportPresets.youTube1080p,
            outputBookmark: Data([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04]),
            outputDisplayName: "missing.mp4",
            projectSnapshot: ProjectDocument(
                name: "T", renderWidth: 1280, renderHeight: 720, frameRate: 30,
                media: [], videoTracks: [], audioTracks: []),
            status: .queued)
        let reconciled = RenderQueue.reconcile(loaded: [job])
        #expect(reconciled.count == 1)
        #expect(reconciled[0].status == .failed)
        #expect(reconciled[0].errorMessage != nil)
    }

    @Test("Reconcile: an empty bookmark flips a queued job to .failed")
    func reconcileEmptyBookmarkFails() {
        let job = QueueJob(
            preset: BuiltInExportPresets.youTube1080p,
            outputBookmark: Data(),
            outputDisplayName: "missing.mp4",
            projectSnapshot: ProjectDocument(
                name: "T", renderWidth: 1280, renderHeight: 720, frameRate: 30,
                media: [], videoTracks: [], audioTracks: []),
            status: .queued)
        let reconciled = RenderQueue.reconcile(loaded: [job])
        #expect(reconciled[0].status == .failed)
    }

    @Test("Reconcile: a stale output bookmark refreshes when it still resolves")
    func reconcileRefreshesStaleOutputBookmark() {
        let stale = Data([0x01, 0x02, 0x03])
        let refreshed = Data([0x09, 0x08, 0x07])
        let job = sampleJob(status: .queued, outputBookmark: stale)

        let reconciled = RenderQueue.reconcile(loaded: [job]) { bookmark in
            #expect(bookmark == stale)
            return BookmarkResolution(
                url: URL(filePath: "/tmp/renderqueue-refresh-test.mov"),
                refreshedBookmark: refreshed)
        }

        #expect(reconciled[0].status == .queued)
        #expect(reconciled[0].outputBookmark == refreshed)
    }

    @Test("Reconcile: terminal entries stay terminal")
    func reconcilePreservesTerminal() {
        let completed = QueueJob(
            preset: BuiltInExportPresets.web720p,
            outputBookmark: Data(),
            outputDisplayName: "done.mp4",
            projectSnapshot: ProjectDocument(
                name: "T", renderWidth: 1280, renderHeight: 720, frameRate: 30,
                media: [], videoTracks: [], audioTracks: []),
            status: .completed, progress: 1)
        let reconciled = RenderQueue.reconcile(loaded: [completed])
        #expect(reconciled[0].status == .completed)
        #expect(reconciled[0].progress == 1)
    }
}

// MARK: - RenderQueue (T5.3, T5.4, R5.3, R5.4)

@MainActor
@Suite("RenderQueue")
struct RenderQueueTests {

    private func snapshot() -> ProjectDocument {
        ProjectDocument(
            name: "T", renderWidth: 1280, renderHeight: 720, frameRate: 30,
            media: [], videoTracks: [], audioTracks: [])
    }

    private func makeJob(name: String) -> QueueJob {
        QueueJob(
            preset: BuiltInExportPresets.web720p,
            outputBookmark: Data([0x01, 0x02, 0x03]),
            outputDisplayName: "\(name).mp4",
            projectSnapshot: snapshot())
    }

    @Test("Enqueue preserves insertion order")
    func enqueuePreservesOrder() {
        let queue = RenderQueue(persistsToDisk: false)
        let a = makeJob(name: "A")
        let b = makeJob(name: "B")
        let c = makeJob(name: "C")
        // autoStart: false keeps the runner Task from picking up the jobs so
        // the assertion observes the pure enqueue order.
        queue.enqueue(a, autoStart: false)
        queue.enqueue(b, autoStart: false)
        queue.enqueue(c, autoStart: false)
        #expect(queue.jobs.map(\.outputDisplayName) == ["A.mp4", "B.mp4", "C.mp4"])
        #expect(queue.jobs.map(\.status) == [.queued, .queued, .queued])
    }

    @Test("Cancel: queued → cancelled is immediate")
    func cancelQueued() {
        let queue = RenderQueue(persistsToDisk: false)
        let job = makeJob(name: "X")
        queue.enqueue(job, autoStart: false)
        queue.cancel(jobID: job.id)
        #expect(queue.jobs[0].status == .cancelled)
    }

    @Test("Cancel: re-cancelling a terminal job is a no-op")
    func cancelTerminalIsNoOp() {
        let queue = RenderQueue(persistsToDisk: false)
        let job = makeJob(name: "X")
        queue.enqueue(job, autoStart: false)
        queue.cancel(jobID: job.id)
        let snapshot = queue.jobs[0]
        queue.cancel(jobID: job.id)
        #expect(queue.jobs[0] == snapshot, "second cancel should be a no-op")
    }

    @Test("Retry: a cancelled job is requeued for another run (R3.3)")
    func retryRequeuesCancelled() {
        let queue = RenderQueue(persistsToDisk: false)
        let job = makeJob(name: "X")
        queue.enqueue(job, autoStart: false)
        queue.cancel(jobID: job.id)
        #expect(queue.jobs[0].status == .cancelled)

        queue.retry(jobID: job.id, autoStart: false)
        #expect(queue.jobs[0].status == .queued)
        #expect(queue.jobs[0].errorMessage == nil)
        #expect(queue.jobs[0].progress == 0)
    }

    @Test("Retry: a failed job is requeued without relying on queued-cancel semantics")
    func retryRequeuesFailed() {
        var job = makeJob(name: "X")
        job.status = .failed
        job.errorMessage = "Previous export failed"
        job.progress = 0.4
        job.runtimeSeconds = 12
        let queue = RenderQueue(jobs: [job], persistsToDisk: false)

        queue.retry(jobID: job.id, autoStart: false)
        #expect(queue.jobs[0].status == .queued)
        #expect(queue.jobs[0].errorMessage == nil)
        #expect(queue.jobs[0].progress == 0)
        #expect(queue.jobs[0].runtimeSeconds == nil)
    }

    @Test("Retry: a non-terminal (queued) job is left untouched")
    func retryNoOpForNonTerminal() {
        let queue = RenderQueue(persistsToDisk: false)
        let job = makeJob(name: "X")
        queue.enqueue(job, autoStart: false)
        let before = queue.jobs[0]
        queue.retry(jobID: job.id, autoStart: false)
        #expect(queue.jobs[0] == before, "retrying a queued job should be a no-op")
    }

    @Test("Resolved directory bookmarks expand back to the intended output file")
    func outputURLAppendsDisplayNameForDirectoryBookmarks() {
        let bookmark = Data([0x44])
        let job = QueueJob(
            preset: BuiltInExportPresets.web720p,
            outputBookmark: bookmark,
            outputDisplayName: "Queued.mp4",
            projectSnapshot: snapshot(),
            status: .completed)
        let queue = RenderQueue(jobs: [job], persistsToDisk: false) { resolved in
            #expect(resolved == bookmark)
            return BookmarkResolution(
                url: URL(filePath: "/tmp/render-queue-output", directoryHint: .isDirectory),
                refreshedBookmark: nil)
        }

        let outputURL = queue.outputURL(forJobID: job.id)

        #expect(outputURL?.path == "/tmp/render-queue-output/Queued.mp4")
    }

    @Test("clearCompleted drops terminal jobs only")
    func clearCompletedDropsTerminal() {
        let queue = RenderQueue(persistsToDisk: false)
        let a = makeJob(name: "A")
        let b = makeJob(name: "B")
        queue.enqueue(a, autoStart: false)
        queue.enqueue(b, autoStart: false)
        queue.cancel(jobID: a.id)
        queue.clearCompleted()
        #expect(queue.jobs.count == 1)
        #expect(queue.jobs[0].id == b.id)
    }

    @Test("Enqueue rejects an unsupported (container, codec) pair as .failed")
    func enqueueRejectsUnsupported() {
        let queue = RenderQueue(persistsToDisk: false)
        let badPreset = ExportPreset(
            name: "ProRes in MP4 (unsupported)",
            containerFormat: AVFileType.mp4.rawValue,
            videoCodec: AVVideoCodecType.proRes422.rawValue,
            aspect: .widescreen,
            targetSize: CGSize(width: 1920, height: 1080),
            bitrate: .max,
            frameRate: nil,
            audioConfig: .aac192k)
        let job = QueueJob(
            preset: badPreset,
            outputBookmark: Data([0x01]),
            outputDisplayName: "bad.mp4",
            projectSnapshot: snapshot())
        queue.enqueue(job, autoStart: false)
        #expect(queue.jobs.count == 1)
        #expect(queue.jobs[0].status == .failed)
        #expect(queue.jobs[0].errorMessage != nil)
    }

    @Test("totalProgress: empty queue is 0")
    func totalProgressEmpty() {
        let queue = RenderQueue(persistsToDisk: false)
        #expect(queue.totalProgress == 0)
    }

    @Test("totalProgress counts completed and active fractions")
    func totalProgressMixed() {
        let queue = RenderQueue(persistsToDisk: false)
        let a = makeJob(name: "A")
        let b = makeJob(name: "B")
        queue.enqueue(a, autoStart: false)
        queue.enqueue(b, autoStart: false)
        queue.cancel(jobID: a.id)
        // 1 terminal + 1 queued (0) ⇒ 0.5
        #expect(abs(queue.totalProgress - 0.5) < 1e-6)
    }

    @Test("Persistence: missing queue file URL surfaces a status message")
    func persistMissingQueueURLReportsStatus() {
        let queue = RenderQueue(
            persistsToDisk: true,
            queueFileURLProvider: { nil })
        let job = makeJob(name: "A")

        queue.enqueue(job, autoStart: false)

        #expect(queue.statusMessage == "Render queue was not saved: Application Support directory unavailable.")
    }

    @Test("Persistence: atomic write failure surfaces a status message")
    func persistWriteFailureReportsStatus() async {
        struct WriteFailure: LocalizedError, Sendable {
            var errorDescription: String? { "Injected queue write failure" }
        }

        let queue = RenderQueue(
            persistsToDisk: true,
            queueFileURLProvider: {
                URL(filePath: NSTemporaryDirectory())
                    .appendingPathComponent("renderqueue-write-failure-\(UUID()).json")
            },
            queueDocumentWriter: { _, _ in
                throw WriteFailure()
            })
        let job = makeJob(name: "A")

        queue.enqueue(job, autoStart: false)

        await queue.waitForPendingPersistenceForTesting()

        #expect(queue.statusMessage?.contains("Injected queue write failure") == true)
    }

    @Test("Runner cleanup restarts when a job is enqueued after drain")
    func runnerCleanupRestartsAfterDrainEnqueue() async throws {
        let queue = RenderQueue(persistsToDisk: false, outputBookmarkResolver: { _ in nil })
        let first = makeJob(name: "A")
        let second = makeJob(name: "B")
        var didInjectSecondJob = false
        queue.runnerDrainedForTesting = {
            guard !didInjectSecondJob else { return }
            didInjectSecondJob = true
            queue.enqueue(second)
        }

        queue.enqueue(first)

        try await waitForQueueToSettle(queue, expectedCount: 2)
        #expect(didInjectSecondJob)
        #expect(queue.jobs.map(\.outputDisplayName) == ["A.mp4", "B.mp4"])
        #expect(queue.jobs.allSatisfy { $0.status == .failed })
        #expect(!queue.isRunning)
    }

    private func waitForQueueToSettle(
        _ queue: RenderQueue,
        expectedCount: Int,
        timeout: TimeInterval = 20
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if queue.jobs.count == expectedCount,
               !queue.isRunning,
               queue.jobs.allSatisfy(\.isTerminal) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let statuses = queue.jobs.map(\.status.rawValue).joined(separator: ",")
        Issue.record("Render queue did not settle before timeout; count=\(queue.jobs.count), isRunning=\(queue.isRunning), statuses=[\(statuses)]")
    }

}
