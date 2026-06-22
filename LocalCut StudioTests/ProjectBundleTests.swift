import Testing
import Foundation
import AVFoundation
import CoreGraphics
@testable import LocalCut_Studio

@MainActor
@Suite("Project Bundles")
struct ProjectBundleTests {

    // MARK: - Helpers

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A fresh temporary directory unique to the calling test. The system
    /// reclaims `NSTemporaryDirectory()` between launches, so test runs don't
    /// pollute long-term state.
    private func makeTempDirectory(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lcbundle-tests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes deterministic bytes to disk and returns its URL. Used to stand in
    /// for an imported media file; the bundle-copy path only needs a real file
    /// to read, not a decodable asset.
    private func writeAsset(_ bytes: [UInt8], name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url, options: .atomic)
        return url
    }

    /// Builds a minimal `ProjectDocument` carrying one media ref + one caption
    /// track, suitable for a bundle round-trip test.
    private func sampleDocument(mediaID: UUID,
                                bundleRelativePath: String?,
                                captionTrackID: UUID) -> ProjectDocument {
        let media = MediaRef(
            id: mediaID,
            displayName: "Sample",
            bookmark: bundleRelativePath == nil ? Data([0xAA]) : Data(),
            duration: CMTimeCode(time(10)),
            naturalWidth: 1920, naturalHeight: 1080,
            preferredTransform: TransformCode(.identity),
            hasVideo: true, hasAudio: false,
            bundleRelativePath: bundleRelativePath)

        let line = CaptionLine(
            range: CMTimeRange(start: time(1), duration: time(2)),
            text: "hello")
        let captionDoc = CaptionTrackDoc(
            id: captionTrackID, name: "Captions",
            isMuted: false, defaultStyle: .identity, lines: [line])

        return ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            bundleFormat: ProjectDocument.currentBundleFormat,
            name: "Sample",
            renderWidth: 1920, renderHeight: 1080, frameRate: 30,
            media: [media],
            videoTracks: [],
            audioTracks: [],
            captionTracks: [captionDoc])
    }

    // MARK: - T6.1 — caption-track UUID round-trips through a bundle

    @Test("Bundle round-trip preserves caption-track UUIDs across multiple saves")
    func bundleRoundTripPreservesCaptionTrackIDs() throws {
        let tmp = try makeTempDirectory("captionid")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("Sample.lcbundle")

        let captionTrackID = UUID()
        let document = sampleDocument(mediaID: UUID(),
                                      bundleRelativePath: nil,
                                      captionTrackID: captionTrackID)
        let originalJSON = try document.encoded()

        // Round 1: save + reopen.
        let firstIndex = try ProjectBundle.write(
            projectJSON: originalJSON, to: bundleURL,
            bundledMedia: [], previousFingerprints: FingerprintIndex())
        #expect(firstIndex.entries.isEmpty) // no bundled media in this fixture

        let contents = try ProjectBundle.read(url: bundleURL)
        #expect(contents.document.captionTracks.count == 1)
        #expect(contents.document.captionTracks[0].id == captionTrackID)
        #expect(contents.document.bundleFormat == ProjectDocument.currentBundleFormat)

        // Round 2: re-save with the round-tripped document, reopen again. The
        // caption track's id must survive both hops; PR #10's stable-id
        // guarantee must not regress through the bundle format.
        let restoredJSON = try contents.document.encoded()
        _ = try ProjectBundle.write(
            projectJSON: restoredJSON, to: bundleURL,
            bundledMedia: [], previousFingerprints: contents.fingerprints)
        let again = try ProjectBundle.read(url: bundleURL)
        #expect(again.document.captionTracks[0].id == captionTrackID)
    }

    // MARK: - T6.2 — fingerprint detects an external edit

    @Test("Fingerprint detects an external edit on a tracked asset")
    func fingerprintDetectsExternalEdit() throws {
        let tmp = try makeTempDirectory("fingerprint")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let asset = try writeAsset([0x01, 0x02, 0x03, 0x04],
                                   name: "asset.bin", in: tmp)
        let original = try Fingerprint.sha256(of: asset)
        #expect(original.count == 64)
        #expect(original.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) })

        // External edit — overwrite the file.
        try Data([0x05, 0x06, 0x07, 0x08]).write(to: asset, options: .atomic)
        let after = try Fingerprint.sha256(of: asset)
        #expect(original != after)
    }

    @Test("Fingerprint index round-trips through Codable with stable sort order")
    func fingerprintIndexCodableRoundTrip() throws {
        let index = FingerprintIndex(entries: [
            "assets/b.mov": "deadbeef",
            "assets/a.mov": "cafef00d",
        ])
        let data = try index.encoded()
        // Sorted-key JSON puts assets/a.mov before assets/b.mov.
        let json = String(data: data, encoding: .utf8) ?? ""
        let aIndex = json.range(of: "assets/a.mov")?.lowerBound
        let bIndex = json.range(of: "assets/b.mov")?.lowerBound
        #expect(aIndex != nil && bIndex != nil)
        if let aIndex, let bIndex { #expect(aIndex < bIndex) }

        let decoded = try FingerprintIndex(data: data)
        #expect(decoded == index)
    }

    @Test("ProjectBundle.write skips the copy when the source still matches the stored fingerprint")
    func bundleFastPathSkipsRecopy() throws {
        let tmp = try makeTempDirectory("fastpath")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = tmp.appendingPathComponent("Sample.lcbundle")
        let mediaID = UUID()
        let relative = ProjectBundleLayout.assetRelativePath(
            mediaID: mediaID, sourceExtension: "bin")
        let source = try writeAsset([0xAA, 0xBB, 0xCC],
                                    name: "source.bin", in: tmp)

        let document = sampleDocument(mediaID: mediaID,
                                      bundleRelativePath: relative,
                                      captionTrackID: UUID())
        let bundled = [
            ProjectBundle.BundledMedia(mediaID: mediaID,
                                       sourceURL: source,
                                       bundleRelativePath: relative)
        ]
        let first = try ProjectBundle.write(
            projectJSON: try document.encoded(),
            to: bundleURL,
            bundledMedia: bundled,
            previousFingerprints: FingerprintIndex())
        #expect(first.entries.count == 1)
        #expect(first.entries[relative] != nil)

        // Snapshot the copy's mtime then re-save with the same fingerprints.
        let assetURL = bundleURL.appendingPathComponent(relative)
        let mtimeBefore = (try assetURL.resourceValues(forKeys: [.contentModificationDateKey]))
            .contentModificationDate

        let second = try ProjectBundle.write(
            projectJSON: try document.encoded(),
            to: bundleURL,
            bundledMedia: bundled,
            previousFingerprints: first)
        let mtimeAfter = (try assetURL.resourceValues(forKeys: [.contentModificationDateKey]))
            .contentModificationDate
        #expect(second == first)
        // The fast path skipped the copy, so the bundled asset's mtime did not move.
        #expect(mtimeBefore == mtimeAfter)
    }

    // MARK: - T6.3 — .lcstudio → .lcbundle conversion preserves everything

    @Test(".lcstudio → .lcbundle conversion preserves clips, captions, presets, and undo history")
    func lcstudioConvertsToBundlePreservingEverything() async throws {
        let tmp = try makeTempDirectory("convert")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Stand in for an imported media file.
        let source = try writeAsset(Array(repeating: 0x42, count: 64),
                                    name: "Clip.mov", in: tmp)

        let model = EditorModel()
        let media = MediaItem(url: source)
        media.duration = time(8)
        media.hasVideo = true
        media.naturalSize = CGSize(width: 1920, height: 1080)
        model.project.mediaItems.append(media)

        // One clip on the timeline + one caption track + a transition + a colour grade.
        var clip = Clip(mediaID: media.id, sourceStart: .zero, duration: time(4),
                        timelineStart: .zero, opacity: 0.75,
                        effects: [.colourGrade(.neutral)])
        clip.transition = Transition(type: .wipe, duration: time(1))
        model.project.videoTracks.first!.clips.append(clip)

        let captionTrack = CaptionTrack(name: "Captions")
        let originalCaptionID = captionTrack.id
        captionTrack.addLine(CaptionLine(
            range: CMTimeRange(start: time(1), duration: time(2)),
            text: "captioned"))
        captionTrack.defaultStyle = .identity
        model.project.captionTracks = [captionTrack]

        // Make sure there is at least one undoable action in the stack, then
        // capture the depth. Convert must not throw it away.
        model.performUndoable("Sample edit") {
            model.project.name = "Convert Sample"
        }
        #expect(model.canUndo == true)
        let undoableBefore = model.canUndo
        let undoTitleBefore = model.undoTitle

        // 1. Save as legacy single-file `.lcstudio`.
        let lcstudioURL = tmp.appendingPathComponent("Convert Sample.lcstudio")
        let savedLegacy = model.writeSynchronously(to: lcstudioURL)
        #expect(savedLegacy == true)
        let lcstudioBytesBefore = try Data(contentsOf: lcstudioURL)

        // 2. Convert to bundle alongside.
        let bundleURL = tmp.appendingPathComponent("Convert Sample.lcbundle")
        await model.convertToBundle(to: bundleURL)
        #expect(model.documentURL == bundleURL)

        // Original `.lcstudio` must be byte-identical (R4.2 — left in place).
        let lcstudioBytesAfter = try Data(contentsOf: lcstudioURL)
        #expect(lcstudioBytesBefore == lcstudioBytesAfter)

        // Undo history preserved (R4.3 — Convert does not clear the stack).
        #expect(model.canUndo == undoableBefore)
        #expect(model.undoTitle == undoTitleBefore)

        // 3. Reopen the bundle from scratch in a separate model.
        let reopener = EditorModel()
        await reopener.open(url: bundleURL)
        #expect(reopener.project.videoTracks.first?.clips.count == 1)
        let restoredClip = reopener.project.videoTracks.first!.clips.first!
        #expect(restoredClip.duration == time(4))
        #expect(restoredClip.opacity == 0.75)
        #expect(restoredClip.transition?.type == .wipe)
        #expect(restoredClip.effects == [.colourGrade(.neutral)])
        #expect(reopener.project.captionTracks.first?.id == originalCaptionID)
        #expect(reopener.project.captionTracks.first?.lines.first?.text == "captioned")
        #expect(reopener.project.mediaItems.count == 1)
        // The reopened media item must point at the bundled copy, not the source.
        #expect(reopener.project.mediaItems.first?.bundleRelativePath != nil)
    }

    // MARK: - T6.4 — mixed copied + bookmarked media

    @Test("MediaRef carries bundleRelativePath for bundled refs and a bookmark for external refs")
    func bundleMixedCopiedAndBookmarkedMedia() throws {
        let bundled = MediaRef(
            id: UUID(),
            displayName: "Bundled",
            bookmark: Data(),
            duration: CMTimeCode(time(5)),
            naturalWidth: 1280, naturalHeight: 720,
            preferredTransform: TransformCode(.identity),
            hasVideo: true, hasAudio: false,
            bundleRelativePath: "assets/aaaa.mov")
        let external = MediaRef(
            id: UUID(),
            displayName: "External",
            bookmark: Data([0xDE, 0xAD]),
            duration: CMTimeCode(time(7)),
            naturalWidth: 1920, naturalHeight: 1080,
            preferredTransform: TransformCode(.identity),
            hasVideo: true, hasAudio: true,
            bundleRelativePath: nil)

        let document = ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            bundleFormat: ProjectDocument.currentBundleFormat,
            name: "Mixed",
            renderWidth: 1920, renderHeight: 1080, frameRate: 30,
            media: [bundled, external],
            videoTracks: [], audioTracks: [])
        let roundTripped = try ProjectDocument(data: try document.encoded())
        #expect(roundTripped.media.count == 2)
        let restoredBundled = roundTripped.media.first { $0.id == bundled.id }!
        let restoredExternal = roundTripped.media.first { $0.id == external.id }!
        #expect(restoredBundled.bundleRelativePath == "assets/aaaa.mov")
        #expect(restoredBundled.bookmark.isEmpty)
        #expect(restoredExternal.bundleRelativePath == nil)
        #expect(restoredExternal.bookmark == Data([0xDE, 0xAD]))
    }

    // MARK: - Single-file path remains backwards-compatible

    @Test("Single-file save downconverts to schemaVersion = 2 with no bundleFormat")
    func singleFileSaveDownconvertsSchemaVersion() async {
        let tmp = try? makeTempDirectory("downconvert")
        guard let tmp else {
            Issue.record("Could not create temp directory")
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = EditorModel()
        let lcstudioURL = tmp.appendingPathComponent("Old.lcstudio")
        _ = model.writeSynchronously(to: lcstudioURL)

        let data = (try? Data(contentsOf: lcstudioURL)) ?? Data()
        guard let document = try? ProjectDocument(data: data) else {
            Issue.record("Saved document did not decode")
            return
        }
        #expect(document.schemaVersion == ProjectDocument.singleFileSchemaVersion)
        #expect(document.bundleFormat == nil)
    }

    // MARK: - Bundle detection

    @Test("ProjectBundle.isBundle accepts .lcbundle directories and rejects unrelated dirs")
    func bundleDetection() throws {
        let tmp = try makeTempDirectory("detect")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Empty directory should not be treated as a bundle.
        let plain = tmp.appendingPathComponent("Plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(ProjectBundle.isBundle(url: plain) == false)

        // A directory with the right extension qualifies on extension alone.
        let lcbundle = tmp.appendingPathComponent("Sample.lcbundle")
        try FileManager.default.createDirectory(at: lcbundle, withIntermediateDirectories: true)
        #expect(ProjectBundle.isBundle(url: lcbundle) == true)
    }
}
