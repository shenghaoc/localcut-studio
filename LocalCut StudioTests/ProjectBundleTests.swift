import Testing
import Foundation
import AVFoundation
import CoreGraphics
import LocalCutCore
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

    @Test("ProjectBundle.write stages metadata and leaves no staged files behind")
    func bundleMetadataStagingCleansUp() throws {
        let tmp = try makeTempDirectory("staged-metadata")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("Sample.lcbundle")
        let document = sampleDocument(mediaID: UUID(),
                                      bundleRelativePath: nil,
                                      captionTrackID: UUID())

        _ = try ProjectBundle.write(
            projectJSON: document.encoded(), to: bundleURL,
            bundledMedia: [], previousFingerprints: FingerprintIndex())

        let names = try FileManager.default.contentsOfDirectory(atPath: bundleURL.path)
        #expect(names.contains(ProjectBundleLayout.projectJSON))
        #expect(names.contains(ProjectBundleLayout.fingerprintsJSON))
        #expect(!names.contains { $0.contains(".staged-") })
    }

    @Test("Bundle cover save removes stale cover file for previous format")
    func bundleCoverSaveRemovesStalePreviousFormat() throws {
        let tmp = try makeTempDirectory("stale-cover")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("Sample.lcbundle")
        let document = sampleDocument(mediaID: UUID(),
                                      bundleRelativePath: nil,
                                      captionTrackID: UUID())

        let pngCover = ProjectBundle.CoverBundleData(
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            fileExtension: "png")
        let firstIndex = try ProjectBundle.write(
            projectJSON: document.encoded(),
            to: bundleURL,
            bundledMedia: [],
            previousFingerprints: FingerprintIndex(),
            coverData: pngCover)

        let pngRelative = ProjectBundleLayout.coverRelativePath(format: "png")
        let pngURL = bundleURL.appendingPathComponent(pngRelative)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
        #expect(firstIndex.entries[pngRelative] != nil)

        let jpgCover = ProjectBundle.CoverBundleData(
            imageData: Data([0xFF, 0xD8, 0xFF]),
            fileExtension: "jpg")
        let secondIndex = try ProjectBundle.write(
            projectJSON: document.encoded(),
            to: bundleURL,
            bundledMedia: [],
            previousFingerprints: firstIndex,
            coverData: jpgCover)

        let jpgRelative = ProjectBundleLayout.coverRelativePath(format: "jpg")
        let jpgURL = bundleURL.appendingPathComponent(jpgRelative)
        #expect(FileManager.default.fileExists(atPath: jpgURL.path))
        #expect(!FileManager.default.fileExists(atPath: pngURL.path))
        #expect(secondIndex.entries[pngRelative] == nil)
        #expect(secondIndex.entries[jpgRelative] != nil)
    }

    @Test("Synchronous bundle save rejects cover generation instead of dropping the cover")
    func synchronousBundleSaveRejectsCoverFrame() throws {
        let tmp = try makeTempDirectory("sync-cover")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("Sample.lcbundle")
        let model = EditorModel()
        model.project.coverFrame = CoverFrameDoc(time: CMTimeCode(.zero))

        #expect(!model.writeSynchronously(to: bundleURL))
        #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
        #expect(model.statusMessage.contains("async Save path"))
    }

    @Test("Bundle save keeps media external when import opts out of copying")
    func bundleDocumentRespectsDontCopyImportFlag() throws {
        let tmp = try makeTempDirectory("dont-copy")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try writeAsset([0x01, 0x02, 0x03], name: "external.mov", in: tmp)
        let model = EditorModel()
        let item = MediaItem(url: source)
        item.wantsBundling = false
        item.bookmark = Data([0xBA, 0x5E])
        model.project.mediaItems.append(item)

        let document = model.makeDocumentForSave(forBundle: true)
        let ref = try #require(document.media.first)

        #expect(ref.bundleRelativePath == nil)
        #expect(ref.bookmark == Data([0xBA, 0x5E]))
    }

    @Test("Bundle save copies overlay sources under assets and strips their bookmarks")
    func bundleSaveCopiesOverlaySources() throws {
        let tmp = try makeTempDirectory("overlay-source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try writeAsset(
            Array("{\"v\":\"5.7.4\",\"fr\":30,\"ip\":0,\"op\":1,\"w\":8,\"h\":8,\"layers\":[]}".utf8),
            name: "sticker.json",
            in: tmp)
        let bundleURL = tmp.appendingPathComponent("OverlayProject.lcbundle")

        let model = EditorModel()
        let overlay = OverlayClip(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sourceType: .lottie,
            timelineStart: time(1),
            duration: time(2))
        model.project.overlays = [overlay]
        model.project.overlayBookmarks[overlay.id] = try source.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)

        #expect(model.writeSynchronously(to: bundleURL))

        let contents = try ProjectBundle.read(url: bundleURL)
        let docOverlay = try #require(contents.document.overlays.first)
        let relativePath = try #require(docOverlay.bundleRelativePath)
        let copiedURL = bundleURL.appendingPathComponent(relativePath)

        #expect(relativePath == "assets/\(overlay.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: copiedURL.path))
        #expect(try Data(contentsOf: copiedURL) == Data(contentsOf: source))
        #expect(docOverlay.bookmark.isEmpty)
        #expect(contents.fingerprints.entries[relativePath] != nil)
    }

    @Test("Single-file save strips stale overlay bundle paths")
    func singleFileSaveStripsOverlayBundlePaths() {
        let model = EditorModel()
        let overlay = OverlayClip(
            sourceType: .animatedImage,
            timelineStart: .zero,
            duration: time(1))
        model.project.overlays = [overlay]
        model.project.overlayBookmarks[overlay.id] = Data([0x01])
        model.project.overlayBundlePaths[overlay.id] = "assets/\(overlay.id.uuidString).gif"

        let document = model.makeDocumentForSave(forBundle: false)

        #expect(document.overlays.first?.bundleRelativePath == nil)
        #expect(document.overlays.first?.bookmark == Data([0x01]))
    }

    @Test("Single-file save converts bundled overlay paths into bookmarks")
    func singleFileSavePreservesBundledOverlaySources() throws {
        let tmp = try makeTempDirectory("overlay-single-file")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("OverlayProject.lcbundle")
        let overlayID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let relativePath = "assets/\(overlayID.uuidString).json"
        let sourceURL = bundleURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"v":"5.7.4","fr":30,"ip":0,"op":1,"w":8,"h":8,"layers":[]}"#.utf8)
            .write(to: sourceURL, options: .atomic)

        let model = EditorModel()
        model.documentURL = bundleURL
        model.project.overlays = [
            OverlayClip(
                id: overlayID,
                sourceType: .lottie,
                timelineStart: .zero,
                duration: time(1)),
        ]
        model.project.overlayBundlePaths[overlayID] = relativePath

        let document = model.makeDocumentForSave(forBundle: false)
        let savedOverlay = try #require(document.overlays.first)

        #expect(savedOverlay.bundleRelativePath == nil)
        #expect(!savedOverlay.bookmark.isEmpty)
    }

    @Test("Single-file save promotes bundled overlay bookmarks back into the live project")
    func singleFileSavePromotesOverlayBookmarksIntoModel() throws {
        let tmp = try makeTempDirectory("overlay-single-file-model")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("OverlayProject.lcbundle")
        let overlayID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let relativePath = "assets/\(overlayID.uuidString).json"
        let sourceURL = bundleURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"v":"5.7.4","fr":30,"ip":0,"op":1,"w":8,"h":8,"layers":[]}"#.utf8)
            .write(to: sourceURL, options: .atomic)

        let model = EditorModel()
        model.documentURL = bundleURL
        model.project.overlays = [
            OverlayClip(
                id: overlayID,
                sourceType: .lottie,
                timelineStart: .zero,
                duration: time(1)),
        ]
        model.project.overlayBundlePaths[overlayID] = relativePath

        let singleFileURL = tmp.appendingPathComponent("OverlayProject.\(ProjectDocument.fileExtension)")
        #expect(model.writeSynchronously(to: singleFileURL))

        #expect(model.project.overlayBundlePaths[overlayID] == nil)
        #expect(!(model.project.overlayBookmarks[overlayID]?.isEmpty ?? true))
        let saved = try ProjectDocument(data: Data(contentsOf: singleFileURL))
        let savedOverlay = try #require(saved.overlays.first)
        #expect(savedOverlay.bundleRelativePath == nil)
        #expect(!savedOverlay.bookmark.isEmpty)
    }

    @Test("Queue snapshot adds bookmarks for bundled overlay sources")
    func queueSnapshotAddsBundledOverlayBookmarks() throws {
        let tmp = try makeTempDirectory("overlay-queue-snapshot")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try writeAsset(
            Array("{\"v\":\"5.7.4\",\"fr\":30,\"ip\":0,\"op\":1,\"w\":8,\"h\":8,\"layers\":[]}".utf8),
            name: "sticker.json",
            in: tmp)
        let bundleURL = tmp.appendingPathComponent("OverlayQueue.lcbundle")

        let model = EditorModel()
        let overlay = OverlayClip(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            sourceType: .lottie,
            timelineStart: time(1),
            duration: time(2))
        model.project.overlays = [overlay]
        model.project.overlayBookmarks[overlay.id] = try source.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)

        #expect(model.writeSynchronously(to: bundleURL))

        let saved = try ProjectBundle.read(url: bundleURL).document
        let savedOverlay = try #require(saved.overlays.first)
        #expect(savedOverlay.bookmark.isEmpty)

        model.project.overlayBookmarks.removeAll()
        let snapshot = ProjectDocument(project: model.project, queueBundleURL: bundleURL)
        let queuedOverlay = try #require(snapshot.overlays.first)

        #expect(queuedOverlay.bundleRelativePath == savedOverlay.bundleRelativePath)
        #expect(!queuedOverlay.bookmark.isEmpty)
    }

    @Test("Bundle save copies padded background image and strips bookmark")
    func bundleSaveCopiesPaddedBackgroundImage() throws {
        let tmp = try makeTempDirectory("padded-background")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try writeAsset([0x89, 0x50, 0x4E, 0x47],
                                    name: "wallpaper.png",
                                    in: tmp)
        let bundleURL = tmp.appendingPathComponent("BackgroundProject.lcbundle")

        let model = EditorModel()
        model.project.paddedBackground = PaddedBackgroundPreset(
            source: .image,
            imageBookmark: try source.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil))

        #expect(model.writeSynchronously(to: bundleURL))

        let contents = try ProjectBundle.read(url: bundleURL)
        let background = try #require(contents.document.paddedBackground)
        let relativePath = try #require(background.imageBundleRelativePath)
        let copiedURL = bundleURL.appendingPathComponent(relativePath)

        #expect(relativePath.hasPrefix("assets/"))
        #expect(relativePath.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: copiedURL.path))
        #expect(try Data(contentsOf: copiedURL) == Data(contentsOf: source))
        #expect(background.imageBookmark == nil)
        #expect(contents.fingerprints.entries[relativePath] != nil)
    }

    @Test("Single-file save converts bundled padded background path into bookmark")
    func singleFileSavePreservesBundledPaddedBackgroundImage() throws {
        let tmp = try makeTempDirectory("padded-background-single-file")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("BackgroundProject.lcbundle")
        let relativePath = "assets/66666666-6666-6666-6666-666666666666.png"
        let sourceURL = bundleURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceURL, options: .atomic)

        let model = EditorModel()
        model.documentURL = bundleURL
        model.project.paddedBackground = PaddedBackgroundPreset(
            source: .image,
            imageBundleRelativePath: relativePath)

        let document = model.makeDocumentForSave(forBundle: false)
        let background = try #require(document.paddedBackground)

        #expect(background.imageBundleRelativePath == nil)
        #expect(background.imageBookmark != nil)
    }

    @Test("Queue snapshot adds bookmark for bundled padded background image")
    func queueSnapshotAddsBundledPaddedBackgroundBookmark() throws {
        let tmp = try makeTempDirectory("padded-background-queue")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("BackgroundQueue.lcbundle")
        let relativePath = "assets/77777777-7777-7777-7777-777777777777.png"
        let sourceURL = bundleURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceURL, options: .atomic)

        let project = Project()
        project.paddedBackground = PaddedBackgroundPreset(
            source: .image,
            imageBundleRelativePath: relativePath)

        let snapshot = ProjectDocument(project: project, queueBundleURL: bundleURL)
        let background = try #require(snapshot.paddedBackground)

        #expect(background.imageBundleRelativePath == relativePath)
        #expect(background.imageBookmark != nil)
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
        // Re-encoding the same value twice produces byte-identical output: the
        // encoder sorts keys itself before emitting. A substring-position
        // check on the raw JSON would be fragile here because JSONEncoder
        // escapes `/` as `\/` in the output.
        let again = try index.encoded()
        #expect(data == again)

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
        clip.transition?.wipeAngle = Transition.radians(fromDegrees: 180)
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

        // After Convert succeeds the live MediaItem in the converted model
        // points at the bundled copy (not the original external file) so a
        // subsequent move/delete of the original doesn't break preview/export.
        let bundledItemURL = bundleURL.appendingPathComponent("assets/\(media.id.uuidString).mov")
        #expect(model.project.mediaItems.first?.url.standardizedFileURL
                == bundledItemURL.standardizedFileURL)
        #expect(model.project.mediaItems.first?.bookmark == nil)

        // 3. Reopen the bundle from scratch in a separate model.
        let reopener = EditorModel()
        await reopener.open(url: bundleURL)
        #expect(reopener.project.videoTracks.first?.clips.count == 1)
        let restoredClip = reopener.project.videoTracks.first!.clips.first!
        #expect(restoredClip.duration == time(4))
        #expect(restoredClip.opacity == 0.75)
        #expect(restoredClip.transition?.type == .wipe)
        #expect(restoredClip.transition?.wipeAngle == Transition.radians(fromDegrees: 180))
        #expect(restoredClip.effects == [.colourGrade(.neutral)])
        #expect(reopener.project.captionTracks.first?.id == originalCaptionID)
        #expect(reopener.project.captionTracks.first?.lines.first?.text == "captioned")
        #expect(reopener.project.mediaItems.count == 1)
        // The reopened media item must point at the bundled copy, not the source.
        #expect(reopener.project.mediaItems.first?.bundleRelativePath != nil)
        #expect(reopener.project.mediaItems.first?.url.standardizedFileURL
                == bundledItemURL.standardizedFileURL)
    }

    // MARK: - P0 regression: undo/redo must not revoke the bundle's security scope

    @Test("Undo's reconcileAccessedURLs leaves bundleAccessURL alone (Claude P0)")
    func undoDoesNotRevokeBundleAccess() {
        let model = EditorModel()
        // Stand in for the open-bundle path: hand the model a bundle URL on
        // `bundleAccessURL` (and not in `accessedURLs`). A non-security-scoped
        // tmp URL is fine here — the test exercises the bookkeeping, not the
        // kernel grant.
        let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Sample.lcbundle")
        model.adoptBundleAccess(bundleURL, didStart: true)
        #expect(model.bundleAccessURL == bundleURL)

        // A media item pointed *inside* the bundle: the per-file URL is what
        // `reconcileAccessedURLs` compares against, and it never equals the
        // bundle root, which is the exact condition that caused the original
        // bug to revoke the bundle grant on undo.
        let mediaURL = bundleURL.appendingPathComponent("assets/dummy.mov")
        let media = MediaItem(url: mediaURL)
        model.project.mediaItems = [media]

        // Drive an undoable mutation, then undo it — applyState calls
        // `reconcileAccessedURLs` along the way.
        model.performUndoable("Edit") {
            model.project.name = "Edited"
        }
        model.undo()

        #expect(model.bundleAccessURL == bundleURL)
        #expect(!model.accessedURLs.contains(bundleURL))
    }

    @Test("Convert: undo of a pre-Convert edit restores the original media (Claude P1)")
    func convertUndoRestoresOriginalMedia() async throws {
        let tmp = try makeTempDirectory("convertundo")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try writeAsset([0xAB, 0xCD], name: "source.bin", in: tmp)

        let model = EditorModel()
        let media = MediaItem(url: source)
        media.duration = time(1)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        // Capture a pre-Convert undoable edit.
        model.performUndoable("Pre-convert edit") {
            model.project.name = "Edited"
        }

        let bundleURL = tmp.appendingPathComponent("Sample.lcbundle")
        await model.convertToBundle(to: bundleURL)

        // The live project should now hold a *different* MediaItem instance
        // pointed at the bundled copy — Convert must replace the item, not
        // mutate its url/asset, otherwise the snapshot held by the pre-edit
        // undo entry would be silently corrupted (its `media` array references
        // the same MediaItem).
        #expect(model.project.mediaItems.first !== media)
        #expect(media.url == source)

        // Undo the pre-Convert edit. The captured snapshot restores its
        // original `[media]` reference — and because we never mutated
        // `media.url`, it still points at the external source.
        model.undo()
        #expect(model.project.mediaItems.count == 1)
        #expect(model.project.mediaItems.first === media)
        #expect(model.project.mediaItems.first?.url == source)
        // The original media object's bundleRelativePath was stamped by
        // convertToBundle before replaceMediaItemsForBundle created the
        // replacement; undo restores the same object, so the stamp is
        // still present. This is safe — bundleRelativePath(for:) returns
        // the pre-set value and writeBundle copies from the external URL.
        #expect(media.bundleRelativePath != nil)
    }

    // MARK: - P1 regression: bundleRelativePath must be validated on read too

    @Test("resolveMedia rejects an unsafe bundleRelativePath from a hostile project.json")
    func bundleResolveRejectsUnsafePath() async throws {
        let tmp = try makeTempDirectory("hostileopen")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("Hostile.lcbundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // A bundle whose project.json claims a bundleRelativePath that escapes
        // the bundle directory. The MediaRef carries no fallback bookmark, so
        // the loader must return `nil` for it (treat as unresolved) — never
        // resolve through the appended path.
        let document = ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            bundleFormat: ProjectDocument.currentBundleFormat,
            name: "Hostile",
            renderWidth: 1920, renderHeight: 1080, frameRate: 30,
            media: [MediaRef(
                id: UUID(), displayName: "Escape", bookmark: Data(),
                duration: CMTimeCode(time(1)),
                naturalWidth: 1920, naturalHeight: 1080,
                preferredTransform: TransformCode(.identity),
                hasVideo: true, hasAudio: false,
                bundleRelativePath: "../escape.mov")],
            videoTracks: [], audioTracks: [])
        try document.encoded().write(to: bundleURL.appendingPathComponent("project.json"))

        let model = EditorModel()
        await model.open(url: bundleURL)
        #expect(model.project.mediaItems.isEmpty)
        #expect(model.unresolvedMedia.count == 1)
    }

    // MARK: - P0 regression: source == destination must not delete the only copy

    @Test("Bundle save with source URL equal to bundled destination keeps the file (review P0)")
    func bundleSaveSourceEqualsDestinationNoDestroy() throws {
        let tmp = try makeTempDirectory("samepath")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("Reopened.lcbundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("assets"),
            withIntermediateDirectories: true)

        let mediaID = UUID()
        let relative = ProjectBundleLayout.assetRelativePath(mediaID: mediaID,
                                                             sourceExtension: "mov")
        // Put the asset directly at the bundled destination — this mimics the
        // state after the user reopens a bundle: MediaItem.url points inside.
        let bundledFile = bundleURL.appendingPathComponent(relative)
        let bytes = Data(repeating: 0x77, count: 32)
        try bytes.write(to: bundledFile)
        let originalDigest = try Fingerprint.sha256(of: bundledFile)

        // No previous fingerprints index — the fast path's stored-digest
        // branch is NOT taken; without the source==destination guard, the
        // write would delete the only copy and then try to copy from it.
        let document = sampleDocument(mediaID: mediaID,
                                      bundleRelativePath: relative,
                                      captionTrackID: UUID())
        let bundled = [
            ProjectBundle.BundledMedia(mediaID: mediaID,
                                       sourceURL: bundledFile,
                                       bundleRelativePath: relative)
        ]
        let index = try ProjectBundle.write(
            projectJSON: try document.encoded(),
            to: bundleURL,
            bundledMedia: bundled,
            previousFingerprints: FingerprintIndex())
        #expect(FileManager.default.fileExists(atPath: bundledFile.path))
        let afterDigest = try Fingerprint.sha256(of: bundledFile)
        #expect(originalDigest == afterDigest)
        #expect(index.entries[relative] == originalDigest)
    }

    // MARK: - Path safety: bundleRelativePath escape rejected

    @Test("Bundle write rejects bundleRelativePath that escapes the bundle directory")
    func bundleWriteRejectsUnsafePath() throws {
        let tmp = try makeTempDirectory("unsafepath")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("Hostile.lcbundle")
        let source = try writeAsset([0x00], name: "source.bin", in: tmp)

        let document = sampleDocument(mediaID: UUID(),
                                      bundleRelativePath: "../escape.mov",
                                      captionTrackID: UUID())
        let bundled = [
            ProjectBundle.BundledMedia(
                mediaID: UUID(),
                sourceURL: source,
                bundleRelativePath: "../escape.mov")
        ]
        #expect(throws: ProjectBundle.WriteError.self) {
            _ = try ProjectBundle.write(
                projectJSON: try document.encoded(),
                to: bundleURL,
                bundledMedia: bundled,
                previousFingerprints: FingerprintIndex())
        }
        // Other unsafe shapes are also caught.
        #expect(ProjectBundleLayout.isSafeAssetRelativePath("assets/ok.mov") == true)
        #expect(ProjectBundleLayout.isSafeAssetRelativePath("../escape.mov") == false)
        #expect(ProjectBundleLayout.isSafeAssetRelativePath("assets/../escape.mov") == false)
        #expect(ProjectBundleLayout.isSafeAssetRelativePath("assets/sub/file.mov") == false)
        #expect(ProjectBundleLayout.isSafeAssetRelativePath("/etc/passwd") == false)
        #expect(ProjectBundleLayout.isSafeAssetRelativePath("assets/") == false)
    }

    @Test("Overlay bundle-relative paths are validated before runtime resolution")
    func overlayBundlePathResolutionRejectsUnsafePaths() throws {
        let tmp = try makeTempDirectory("overlay-unsafe-path")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleURL = tmp.appendingPathComponent("UnsafeOverlay.lcbundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent(ProjectBundleLayout.assetsSubdirectory),
            withIntermediateDirectories: true)
        let escaped = tmp.appendingPathComponent("escape.gif")
        try Data([0x47, 0x49, 0x46]).write(to: escaped, options: .atomic)

        let model = EditorModel()
        let overlay = OverlayClip(sourceType: .animatedImage,
                                  timelineStart: .zero,
                                  duration: time(1))
        model.project.overlays = [overlay]
        model.project.overlayBundlePaths[overlay.id] = "../escape.gif"
        model.documentURL = bundleURL

        #expect(model.resolveOverlayURL(for: overlay) == nil)
    }

    // MARK: - Fingerprint JSON shape (review P2)

    @Test("fingerprints.json is a top-level path → digest map, not nested under 'entries'")
    func fingerprintIndexJSONTopLevel() throws {
        let index = FingerprintIndex(entries: ["assets/a.mov": "deadbeef"])
        let data = try index.encoded()
        let parsed = try JSONSerialization.jsonObject(with: data)
        let dict = parsed as? [String: Any]
        #expect(dict != nil)
        // The map sits at the JSON root: there is no `entries` wrapper key.
        #expect(dict?["entries"] == nil)
        #expect((dict?["assets/a.mov"] as? String) == "deadbeef")
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

    @Test("Single-file save downconverts to the single-file schema version with no bundleFormat")
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
