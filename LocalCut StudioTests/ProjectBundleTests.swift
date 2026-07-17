import Testing
import AppKit
import Foundation
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers
import LocalCutCore
@testable import LocalCut_Studio

@MainActor
@Suite("Project Bundles")
struct ProjectBundleTests {

    @Test("Bundle UTI carries the lcbundle filename tag for save panels")
    func bundleUTIUsesBundleExtension() {
        #expect(UTType.lcStudioProjectBundle.preferredFilenameExtension == ProjectBundleLayout.fileExtension)
        #expect(UTType.lcStudioProjectBundle.conforms(to: .package))
    }

    @Test("Project save panel defaults to a bundle without appending lcstudio")
    func projectSavePanelDefaultsToBundle() {
        let panel = NSSavePanel()
        ProjectSavePanelConfiguration.apply(to: panel, suggestedName: "Untitled")

        #expect(panel.allowedContentTypes == [.lcStudioProjectBundle, .lcStudioProject])
        #expect(panel.currentContentType == .lcStudioProjectBundle)
        #expect(panel.showsContentTypes)
        #expect(panel.nameFieldStringValue == "Untitled.\(ProjectBundleLayout.fileExtension)")
        #expect(ProjectSavePanelConfiguration.filename("Untitled.lcstudio", for: .lcStudioProjectBundle)
                == "Untitled.lcbundle")
        #expect(ProjectSavePanelConfiguration.filename("Untitled.lcbundle", for: .lcStudioProject)
                == "Untitled.lcstudio")
    }

    @Test("Async bundle save marks an unchanged project clean")
    func asyncBundleSaveMarksStableProjectClean() async throws {
        try await withTempDirectory("async-clean") { temporaryDirectory in
            let model = EditorModel()
            model.addMarkerAtPlayhead()
            #expect(model.isDirty)

            let bundleURL = temporaryDirectory.appendingPathComponent("Saved.lcbundle")
            await model.saveAs(url: bundleURL)

            #expect(model.documentURL == bundleURL)
            #expect(!model.isDirty)
        }
    }

    @Test("Project open panel selects bundles as documents")
    func projectOpenPanelTreatsBundlesAsDocuments() {
        let panel = NSOpenPanel()
        ProjectOpenPanelConfiguration.apply(to: panel)

        #expect(!panel.treatsFilePackagesAsDirectories)
        #expect(panel.canChooseDirectories)
        #expect(panel.canChooseFiles)
        #expect(panel.allowedContentTypes.isEmpty)
    }

    @Test("Project open policy rejects unrelated folders and unvalidated packages")
    func projectOpenPolicyValidatesDirectoryCandidates() throws {
        try withTempDirectory("open-policy") { temporaryDirectory in
            #expect(!ProjectOpenPanelConfiguration.isSupportedProjectURL(temporaryDirectory))

            let emptyJSONBundle = temporaryDirectory.appendingPathComponent("EmptyJSON.lcbundle")
            try FileManager.default.createDirectory(at: emptyJSONBundle, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: emptyJSONBundle.appendingPathComponent(ProjectBundleLayout.projectJSON))
            #expect(!ProjectOpenPanelConfiguration.isSupportedProjectURL(emptyJSONBundle))

            let validBundle = temporaryDirectory.appendingPathComponent("Project.lcbundle")
            try FileManager.default.createDirectory(at: validBundle, withIntermediateDirectories: true)
            try writeValidatedBundleMetadata(to: validBundle, name: "Project")
            #expect(ProjectOpenPanelConfiguration.isSupportedProjectURL(validBundle))

            let flatProject = temporaryDirectory.appendingPathComponent("Legacy.lcstudio")
            try Data("{}".utf8).write(to: flatProject)
            #expect(ProjectOpenPanelConfiguration.isSupportedProjectURL(flatProject))

            let malformedStudio = temporaryDirectory.appendingPathComponent("Broken.lcstudio")
            try Data("{not-json".utf8).write(to: malformedStudio)
            #expect(!ProjectOpenPanelConfiguration.isSupportedProjectURL(malformedStudio))

            let misleadingProjectDirectory = temporaryDirectory.appendingPathComponent("NotAProject.lcstudio")
            try FileManager.default.createDirectory(at: misleadingProjectDirectory, withIntermediateDirectories: true)
            #expect(!ProjectOpenPanelConfiguration.isSupportedProjectURL(misleadingProjectDirectory))

            let emptyBundleDirectory = temporaryDirectory.appendingPathComponent("Empty.lcbundle")
            try FileManager.default.createDirectory(at: emptyBundleDirectory, withIntermediateDirectories: true)
            #expect(!ProjectOpenPanelConfiguration.isSupportedProjectURL(emptyBundleDirectory))

            let misleadingBundleFile = temporaryDirectory.appendingPathComponent("NotABundle.lcbundle")
            try Data("not a package".utf8).write(to: misleadingBundleFile)
            #expect(!ProjectOpenPanelConfiguration.isSupportedProjectURL(misleadingBundleFile))

            let malformedJSONBundle = temporaryDirectory.appendingPathComponent("BadJSON.lcbundle")
            try FileManager.default.createDirectory(at: malformedJSONBundle, withIntermediateDirectories: true)
            try Data("{not-json".utf8).write(to: malformedJSONBundle.appendingPathComponent(ProjectBundleLayout.projectJSON))
            #expect(!ProjectOpenPanelConfiguration.isSupportedProjectURL(malformedJSONBundle))

            let missingFormatBundle = temporaryDirectory.appendingPathComponent("NoFormat.lcbundle")
            try FileManager.default.createDirectory(at: missingFormatBundle, withIntermediateDirectories: true)
            var doc = ProjectDocument(
                name: "NoFormat",
                renderWidth: 1920,
                renderHeight: 1080,
                frameRate: 30,
                media: [],
                videoTracks: [],
                audioTracks: []
            )
            doc.bundleFormat = nil
            try doc.encoded().write(to: missingFormatBundle.appendingPathComponent(ProjectBundleLayout.projectJSON))
            #expect(!ProjectOpenPanelConfiguration.isSupportedProjectURL(missingFormatBundle))
        }
    }

    private func writeValidatedBundleMetadata(to directory: URL, name: String) throws {
        var document = ProjectDocument(
            name: name,
            renderWidth: 1920,
            renderHeight: 1080,
            frameRate: 30,
            media: [],
            videoTracks: [],
            audioTracks: []
        )
        document.bundleFormat = ProjectDocument.currentBundleFormat
        try document.encoded().write(to: directory.appendingPathComponent(ProjectBundleLayout.projectJSON))
    }

    // MARK: - Helpers

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A fresh temporary directory unique to the calling test. The system
    /// reclaims `NSTemporaryDirectory()` between launches, so test runs don't
    /// pollute long-term state.
    private func makeTempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lcbundle-tests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a temporary directory, runs `body` with its URL, then cleans up.
    private func withTempDirectory(_ label: String, _ body: (URL) throws -> Void) throws {
        let tmp = try makeTempDirectory(label)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try body(tmp)
    }

    /// Async variant of `withTempDirectory`.
    private func withTempDirectory(_ label: String, _ body: (URL) async throws -> Void) async throws {
        let tmp = try makeTempDirectory(label)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await body(tmp)
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
        try withTempDirectory("captionid") { tmp in
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
    }

    @Test("Bundle round-trip preserves screencast event logs")
    func bundleRoundTripPreservesScreencastEventLogs() throws {
        try withTempDirectory("eventlog") { tmp in
            let bundleURL = tmp.appendingPathComponent("Sample.lcbundle")
            let sessionID = UUID()
            var document = sampleDocument(
                mediaID: UUID(),
                bundleRelativePath: nil,
                captionTrackID: UUID())
            document.screencastEventLogs = [
                ScreencastEventLog(
                    sessionID: sessionID,
                    events: [
                        ScreencastEvent(
                            time: time(0.2),
                            kind: .mouseDown,
                            position: CGPoint(x: 0.35, y: 0.44)),
                    ]),
            ]

            _ = try ProjectBundle.write(
                projectJSON: document.encoded(),
                to: bundleURL,
                bundledMedia: [],
                previousFingerprints: FingerprintIndex())

            let contents = try ProjectBundle.read(url: bundleURL)
            #expect(contents.document.screencastEventLogs.count == 1)
            #expect(contents.document.screencastEventLogs.first?.sessionID == sessionID)
            #expect(contents.document.screencastEventLogs.first?.events.first?.position == CGPoint(x: 0.35, y: 0.44))
        }
    }

    @Test("ProjectBundle.write stages metadata and leaves no staged files behind")
    func bundleMetadataStagingCleansUp() throws {
        try withTempDirectory("staged-metadata") { tmp in
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
    }

    @Test("Bundle project.otio uses fresh asset fingerprints")
    func bundleProjectOtioUsesFreshAssetFingerprints() throws {
        try withTempDirectory("otio-fingerprint") { tmp in
            let bundleURL = tmp.appendingPathComponent("Sample.lcbundle")
            let mediaID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            let source = try writeAsset([0x10, 0x20, 0x30], name: "TestMedia.mov", in: tmp)
            let model = EditorModel()
            model.project.name = "Sample"
            let item = MediaItem(url: source, id: mediaID)
            item.name = "TestMedia.mov"
            item.duration = time(1)
            item.naturalSize = CGSize(width: 1920, height: 1080)
            item.hasVideo = true
            item.hasAudio = false
            item.wantsBundling = true
            model.project.mediaItems = [item]
            let track = Track(name: "V1", kind: .video)
            track.clips = [
                Clip(mediaID: mediaID,
                     sourceStart: .zero,
                     duration: time(1),
                     timelineStart: .zero),
            ]
            model.project.videoTracks = [track]

            #expect(model.writeSynchronously(to: bundleURL))

            let contents = try ProjectBundle.read(url: bundleURL)
            let relative = try #require(contents.document.media.first?.bundleRelativePath)
            let digest = try #require(contents.fingerprints.entries[relative])
            let otioURL = bundleURL.appendingPathComponent(ProjectBundleLayout.projectOTIO)
            let otio = try String(contentsOf: otioURL, encoding: .utf8)
            let escapedRelative = relative.replacingOccurrences(of: "/", with: "\\/")

            #expect(otio.contains("\"target_url\" : \"\(relative)\"") ||
                    otio.contains("\"target_url\" : \"\(escapedRelative)\""))
            #expect(otio.contains("\"fingerprint\" : \"\(digest)\""))
            #expect(validateOtioDocument(otio).isEmpty)
        }
    }

    @Test("Bundle save removes stale project.otio when OTIO data is nil")
    func bundleSaveRemovesStaleOtio() throws {
        try withTempDirectory("stale-otio") { tmp in
            let bundleURL = tmp.appendingPathComponent("Stale.lcbundle")
            let mediaID = UUID()
            let document = sampleDocument(mediaID: mediaID,
                                          bundleRelativePath: "assets/\(mediaID.uuidString).mov",
                                          captionTrackID: UUID())

            // First save creates project.otio.
            try ProjectBundle.write(
                projectJSON: document.encoded(),
                to: bundleURL,
                bundledMedia: [],
                previousFingerprints: FingerprintIndex())
            let otioURL = bundleURL.appendingPathComponent(ProjectBundleLayout.projectOTIO)
            // Simulate a stale sidecar by writing a dummy file.
            try "stale".write(to: otioURL, atomically: true, encoding: .utf8)
            #expect(FileManager.default.fileExists(atPath: otioURL.path))

            // Verify DocumentController removes the stale sidecar when called
            // with nil data (as it does when serialization fails).
            let controller = DocumentController()
            let result = controller.writeProjectOtio(nil, to: bundleURL)
            #expect(!result) // Returns false on nil data.
            #expect(!FileManager.default.fileExists(atPath: otioURL.path))
        }
    }

    @Test("Bundle cover save removes stale cover file for previous format")
    func bundleCoverSaveRemovesStalePreviousFormat() throws {
        try withTempDirectory("stale-cover") { tmp in
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
    }

    @Test("Synchronous bundle save rejects cover generation instead of dropping the cover")
    func synchronousBundleSaveRejectsCoverFrame() throws {
        try withTempDirectory("sync-cover") { tmp in
            let bundleURL = tmp.appendingPathComponent("Sample.lcbundle")
            let model = EditorModel()
            model.project.coverFrame = CoverFrameDoc(time: CMTimeCode(.zero))

            #expect(!model.writeSynchronously(to: bundleURL))
            #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
            #expect(model.statusMessage.contains("async Save path"))
        }
    }

    @Test("Bundle save keeps media external when import opts out of copying")
    func bundleDocumentRespectsDontCopyImportFlag() throws {
        try withTempDirectory("dont-copy") { tmp in
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
    }

    @Test("Bundle save copies overlay sources under assets and strips their bookmarks")
    func bundleSaveCopiesOverlaySources() throws {
        try withTempDirectory("overlay-source") { tmp in
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
        try withTempDirectory("overlay-single-file") { tmp in
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
            model.projectStorageKind = .bundle
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
    }

    @Test("Single-file save promotes bundled overlay bookmarks back into the live project")
    func singleFileSavePromotesOverlayBookmarksIntoModel() throws {
        try withTempDirectory("overlay-single-file-model") { tmp in
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
            model.projectStorageKind = .bundle
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
    }

    @Test("Queue snapshot adds bookmarks for bundled overlay sources")
    func queueSnapshotAddsBundledOverlayBookmarks() throws {
        try withTempDirectory("overlay-queue-snapshot") { tmp in
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
            try FileManager.default.removeItem(
                at: bundleURL.appendingPathComponent(ProjectBundleLayout.projectJSON))
            let snapshot = ProjectDocument(
                project: model.project,
                queueBundleURL: bundleURL,
                queueStorageKind: .bundle)
            let queuedOverlay = try #require(snapshot.overlays.first)

            #expect(queuedOverlay.bundleRelativePath == savedOverlay.bundleRelativePath)
            #expect(!queuedOverlay.bookmark.isEmpty)
        }
    }

    @Test("Bundle save copies padded background image and strips bookmark")
    func bundleSaveCopiesPaddedBackgroundImage() throws {
        try withTempDirectory("padded-background") { tmp in
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
    }

    @Test("Single-file save converts bundled padded background path into bookmark")
    func singleFileSavePreservesBundledPaddedBackgroundImage() throws {
        try withTempDirectory("padded-background-single-file") { tmp in
            let bundleURL = tmp.appendingPathComponent("BackgroundProject.lcbundle")
            let relativePath = "assets/66666666-6666-6666-6666-666666666666.png"
            let sourceURL = bundleURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: sourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceURL, options: .atomic)

            let model = EditorModel()
            model.documentURL = bundleURL
            model.projectStorageKind = .bundle
            model.project.paddedBackground = PaddedBackgroundPreset(
                source: .image,
                imageBundleRelativePath: relativePath)

            let document = model.makeDocumentForSave(forBundle: false)
            let background = try #require(document.paddedBackground)

            #expect(background.imageBundleRelativePath == nil)
            #expect(background.imageBookmark != nil)
        }
    }

    @Test("Queue snapshot adds bookmark for bundled padded background image")
    func queueSnapshotAddsBundledPaddedBackgroundBookmark() throws {
        try withTempDirectory("padded-background-queue") { tmp in
            let bundleURL = tmp.appendingPathComponent("BackgroundQueue.lcbundle")
            let relativePath = "assets/77777777-7777-7777-7777-777777777777.png"
            let sourceURL = bundleURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: sourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceURL, options: .atomic)
            try writeValidatedBundleMetadata(to: bundleURL, name: "BackgroundQueue")

            let project = Project()
            project.paddedBackground = PaddedBackgroundPreset(
                source: .image,
                imageBundleRelativePath: relativePath)

            let snapshot = ProjectDocument(
                project: project,
                queueBundleURL: bundleURL,
                queueStorageKind: .bundle)
            let background = try #require(snapshot.paddedBackground)

            #expect(background.imageBundleRelativePath == relativePath)
            #expect(background.imageBookmark != nil)
        }
    }

    // MARK: - T6.2 — fingerprint detects an external edit

    @Test("Fingerprint detects an external edit on a tracked asset")
    func fingerprintDetectsExternalEdit() throws {
        try withTempDirectory("fingerprint") { tmp in
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
        try withTempDirectory("fastpath") { tmp in
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
    }

    // MARK: - T6.3 — .lcstudio → .lcbundle conversion preserves everything

    @Test(".lcstudio → .lcbundle conversion preserves clips, captions, presets, and undo history")
    func lcstudioConvertsToBundlePreservingEverything() async throws {
        try await withTempDirectory("convert") { tmp in
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
    }

    // MARK: - P0 regression: undo/redo must not revoke the bundle's security scope

    @Test("Undo's reconcileAccessedURLs leaves bundleAccessURL alone (Claude P0)")
    func undoDoesNotRevokeBundleAccess() {
        let model = EditorModel()
        // Stand in for the open-bundle path: hand the model a bundle URL on
        // `bundleAccessURL` (and not in `accessedURLs`). A non-security-scoped
        // tmp URL is fine here — the test exercises the bookkeeping, not the
        // kernel grant.
        let bundleURL = FileManager.default.temporaryDirectory
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
        try await withTempDirectory("convertundo") { tmp in
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
    }

    // MARK: - P1 regression: bundleRelativePath must be validated on read too

    /// Cases for the parameterized unsafe-path test. Each exercises a different
    /// entry point that must reject a `bundleRelativePath` escaping the bundle.
    enum UnsafePathCase: String, CaseIterable, CustomTestStringConvertible {
        case resolveOnOpen
        case writeBundle
        case overlayResolution

        var description: String { rawValue }
        var testDescription: String { rawValue }
    }

    @Test("Unsafe bundleRelativePath is rejected on open, write, and overlay resolution",
          arguments: UnsafePathCase.allCases)
    func unsafePathRejected(_ pathCase: UnsafePathCase) async throws {
        try await withTempDirectory("unsafe-path-\(pathCase.rawValue)") { tmp in
            switch pathCase {
            case .resolveOnOpen:
                // A bundle whose project.json claims a bundleRelativePath that
                // escapes the bundle directory. The MediaRef carries no fallback
                // bookmark, so the loader must return `nil` for it — never
                // resolve through the appended path.
                let bundleURL = tmp.appendingPathComponent("Hostile.lcbundle")
                try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

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

            case .writeBundle:
                let bundleURL = tmp.appendingPathComponent("Hostile.lcbundle")
                let source = try writeAsset([0x00], name: "source.bin", in: tmp)

                let document = sampleDocument(mediaID: UUID(),
                                              bundleRelativePath: "../escape.mov",
                                              captionTrackID: UUID())
                let bundled = [
                    ProjectBundle.BundledMedia(
                        mediaID: UUID(),
                        sourceURL: source,
                        bundleRelativePath: "../escape.mov"),
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

            case .overlayResolution:
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
        }
    }

    // MARK: - P0 regression: source == destination must not delete the only copy

    @Test("Bundle save with source URL equal to bundled destination keeps the file (review P0)")
    func bundleSaveSourceEqualsDestinationNoDestroy() throws {
        try withTempDirectory("samepath") { tmp in
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
    func singleFileSaveDownconvertsSchemaVersion() throws {
        try withTempDirectory("downconvert") { tmp in
            let model = EditorModel()
            let lcstudioURL = tmp.appendingPathComponent("Old.lcstudio")
            _ = model.writeSynchronously(to: lcstudioURL)

            let data = try Data(contentsOf: lcstudioURL)
            let document = try ProjectDocument(data: data)
            #expect(document.schemaVersion == ProjectDocument.singleFileSchemaVersion)
            #expect(document.bundleFormat == nil)
        }
    }

    // MARK: - Bundle detection / storage kind

    @Test("ProjectLocationInspector validates single-file and bundle locations")
    func projectLocationInspectorClassification() throws {
        try withTempDirectory("inspect") { tmp in
            let plain = tmp.appendingPathComponent("Plain")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            #expect(ProjectLocationInspector.inspect(plain) == nil)
            #expect(ProjectBundle.isBundle(url: plain) == false)

            let emptyLcbundle = tmp.appendingPathComponent("Empty.lcbundle")
            try FileManager.default.createDirectory(at: emptyLcbundle, withIntermediateDirectories: true)
            #expect(ProjectLocationInspector.inspect(emptyLcbundle) == nil)
            #expect(ProjectBundle.isBundle(url: emptyLcbundle) == false)

            let emptyJSON = tmp.appendingPathComponent("EmptyJSON.lcbundle")
            try FileManager.default.createDirectory(at: emptyJSON, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: emptyJSON.appendingPathComponent(ProjectBundleLayout.projectJSON))
            #expect(ProjectLocationInspector.inspect(emptyJSON) == nil)

            let lcbundleFile = tmp.appendingPathComponent("NotAPackage.lcbundle")
            try Data("bytes".utf8).write(to: lcbundleFile)
            #expect(ProjectLocationInspector.inspect(lcbundleFile) == nil)

            let valid = tmp.appendingPathComponent("Sample.lcbundle")
            try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
            try writeValidatedBundleMetadata(to: valid, name: "Sample")
            let validDescriptor = ProjectLocationInspector.inspect(valid)
            #expect(validDescriptor?.storageKind == .bundle)
            #expect(ProjectBundle.isBundle(url: valid) == true)

            let studio = tmp.appendingPathComponent("Legacy.lcstudio")
            try Data("{}".utf8).write(to: studio)
            #expect(ProjectLocationInspector.inspect(studio)?.storageKind == .singleFile)

            let uppercaseStudio = tmp.appendingPathComponent("Uppercase.LCSTUDIO")
            try Data("{}".utf8).write(to: uppercaseStudio)
            #expect(ProjectLocationInspector.inspect(uppercaseStudio)?.storageKind == .singleFile)
            #expect(ProjectLocationInspector.storageKindForSaveDestination(
                url: tmp.appendingPathComponent("Output.LCBUNDLE")) == .bundle)
            #expect(ProjectLocationInspector.storageKindForSaveDestination(
                url: tmp.appendingPathComponent("Output.LCSTUDIO")) == .singleFile)

            let malformedStudio = tmp.appendingPathComponent("Broken.lcstudio")
            try Data("{".utf8).write(to: malformedStudio)
            #expect(ProjectLocationInspector.inspect(malformedStudio) == nil)

            let oversizedStudio = tmp.appendingPathComponent("RenamedVideo.lcstudio")
            #expect(FileManager.default.createFile(atPath: oversizedStudio.path, contents: nil))
            let oversizedStudioHandle = try FileHandle(forWritingTo: oversizedStudio)
            try oversizedStudioHandle.truncate(
                atOffset: UInt64(ProjectLocationInspector.maximumMetadataSize + 1))
            try oversizedStudioHandle.close()
            #expect(ProjectLocationInspector.inspect(oversizedStudio) == nil)

            let oversizedBundle = tmp.appendingPathComponent("Oversized.lcbundle")
            try FileManager.default.createDirectory(
                at: oversizedBundle,
                withIntermediateDirectories: true)
            let oversizedProjectJSON = oversizedBundle.appendingPathComponent(
                ProjectBundleLayout.projectJSON)
            #expect(FileManager.default.createFile(atPath: oversizedProjectJSON.path, contents: nil))
            let oversizedBundleHandle = try FileHandle(forWritingTo: oversizedProjectJSON)
            try oversizedBundleHandle.truncate(
                atOffset: UInt64(ProjectLocationInspector.maximumMetadataSize + 1))
            try oversizedBundleHandle.close()
            #expect(ProjectLocationInspector.inspect(oversizedBundle) == nil)

            // Extensionless synced bundle: accepted only with full metadata.
            let renamed = tmp.appendingPathComponent("Synced Project")
            try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: renamed.appendingPathComponent(ProjectBundleLayout.projectJSON))
            #expect(ProjectLocationInspector.inspect(renamed) == nil)

            try writeValidatedBundleMetadata(to: renamed, name: "Synced")
            #expect(ProjectLocationInspector.inspect(renamed)?.storageKind == .bundle)
        }
    }

    @Test("Open Recent keeps extensionless validated bundles")
    func recentProjectFilteringUsesProjectLocationInspector() throws {
        try withTempDirectory("recent-projects") { tmp in
            let extensionlessBundle = tmp.appendingPathComponent("Synced Project")
            try FileManager.default.createDirectory(
                at: extensionlessBundle,
                withIntermediateDirectories: true)
            try writeValidatedBundleMetadata(to: extensionlessBundle, name: "Synced")

            let unrelatedDirectory = tmp.appendingPathComponent("Not a project")
            try FileManager.default.createDirectory(
                at: unrelatedDirectory,
                withIntermediateDirectories: true)

            #expect(DocumentCommands.supportedRecentProjectURLs(
                from: [extensionlessBundle, unrelatedDirectory]) == [extensionlessBundle])
        }
    }

    @Test("Save preserves stored bundle kind for an extensionless validated bundle")
    func savePreservesStoredExtensionlessBundleKind() async throws {
        try await withTempDirectory("extless-save") { tmp in
            let bundle = tmp.appendingPathComponent("Synced Project")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try writeValidatedBundleMetadata(to: bundle, name: "Synced")

            let model = EditorModel()
            await model.open(url: bundle)
            #expect(model.documentURL == bundle)
            #expect(model.projectStorageKind == .bundle)

            model.project.name = "Resaved Synced Project"
            model.isDirty = true
            await model.save()

            #expect(model.projectStorageKind == .bundle)
            #expect(model.documentURL == bundle)
            #expect(try ProjectBundle.read(url: bundle).document.name == "Resaved Synced Project")
            #expect(try ProjectBundle.read(url: bundle).document.bundleFormat
                    == ProjectDocument.currentBundleFormat)
        }
    }

    @Test("Save As dispatches from the destination representation")
    func saveAsUsesDestinationRepresentation() async throws {
        try await withTempDirectory("save-as-kind") { tmp in
            let model = EditorModel()
            model.project.name = "Formats"

            let bundleURL = tmp.appendingPathComponent("Out.LCBUNDLE")
            await model.saveAs(url: bundleURL)
            #expect(model.projectStorageKind == .bundle)
            #expect(model.documentURL == bundleURL)
            #expect(FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(ProjectBundleLayout.projectJSON).path))

            let studioURL = tmp.appendingPathComponent("Out.LCSTUDIO")
            await model.saveAs(url: studioURL)
            #expect(model.projectStorageKind == .singleFile)
            #expect(model.documentURL == studioURL)
            #expect(FileManager.default.isReadableFile(atPath: studioURL.path))
        }
    }

    @Test("Save refuses to treat an unrelated directory as a bundle")
    func saveDoesNotAdoptUnrelatedDirectory() async throws {
        try await withTempDirectory("no-adopt") { tmp in
            let unrelated = tmp.appendingPathComponent("RandomFolder")
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

            let model = EditorModel()
            model.project.name = "ShouldNotWrite"
            await model.saveAs(url: unrelated)

            #expect(model.documentURL == nil)
            #expect(model.projectStorageKind == nil)
            #expect(!FileManager.default.fileExists(
                atPath: unrelated.appendingPathComponent(ProjectBundleLayout.projectJSON).path))
            #expect(model.statusMessage.contains("Save failed"))
        }
    }
}
