import Foundation
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import LocalCutCore

extension EditorModel {
    var selectedSafeZoneProfile: SafeZoneProfile? {
        SafeZoneLibrary.profile(id: selectedSafeZoneProfileID)
    }

    /// Surfaces any safe-zone JSON load/validation errors through `statusMessage`.
    /// Safe to call whenever the safe-zone UI is presented; errors never crash
    /// preview or export.
    func surfaceSafeZoneLoadErrors() {
        let errors = SafeZoneLibrary.loadErrors
        guard !errors.isEmpty else { return }
        let message = errors.count == 1
            ? "Safe zone: \(errors[0])"
            : "\(errors.count) safe-zone profiles failed to load."
        statusMessage = message
    }

    func setCoverTimeToPlayhead() {
        let time = CMTime(seconds: max(0, currentTime), preferredTimescale: 600)
        performUndoable("Set Cover Frame") {
            var cover = project.coverFrame ?? CoverFrameDoc(time: CMTimeCode(time))
            cover.time = CMTimeCode(time)
            project.coverFrame = cover
        }
    }

    func nudgeCoverFrame(byFrames frames: Int) {
        let fps = project.frameRate.isFinite && project.frameRate > 0 ? project.frameRate : 30
        let current = project.coverFrame?.time.cmTime.seconds ?? currentTime
        let frameStep = Double(frames) / fps
        let lastFrame = max(0, totalDuration - (1.0 / fps))
        let seconds = min(max(0, current + frameStep), lastFrame)
        performUndoable("Nudge Cover Frame") {
            var cover = project.coverFrame
                ?? CoverFrameDoc(time: CMTimeCode(CMTime(seconds: max(0, current), preferredTimescale: 600)))
            cover.time = CMTimeCode(CMTime(seconds: seconds, preferredTimescale: 600))
            project.coverFrame = cover
        }
    }

    func setCoverFormat(_ format: CoverFormat) {
        performUndoable("Set Cover Format") {
            var cover = project.coverFrame
                ?? CoverFrameDoc(time: CMTimeCode(CMTime(seconds: max(0, currentTime), preferredTimescale: 600)))
            cover.format = format
            project.coverFrame = cover
        }
    }

    func setCoverTitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        performCoalescedUndoable("Set Cover Title", target: "cover-title", rebuild: .skip) {
            var cover = project.coverFrame
                ?? CoverFrameDoc(time: CMTimeCode(CMTime(seconds: max(0, currentTime), preferredTimescale: 600)))
            cover.title = trimmed.isEmpty ? nil : CoverTitleDoc(text: trimmed)
            project.coverFrame = cover
        }
    }

    func exportCover(to url: URL) async {
        do {
            let data = try await makeCoverImageData()
            try await Task.detached {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                try data.write(to: url, options: .atomic)
            }.value
            statusMessage = "Exported cover \(url.lastPathComponent)."
        } catch {
            statusMessage = "Cover export failed: \(error.localizedDescription)"
        }
    }

    func makeCoverImageData() async throws -> Data {
        let cover = project.coverFrame
            ?? CoverFrameDoc(time: CMTimeCode(CMTime(seconds: max(0, currentTime), preferredTimescale: 600)))
        guard let built = try await CompositionBuilder.build(project: project) else {
            throw CoverExportError.emptyProject
        }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Render the cover from a frame strictly inside the timeline: requesting
        // exactly at `duration` (the exclusive end) can fail to produce an image.
        let seconds = Self.snappedCoverFrameSeconds(
            requested: cover.time.cmTime.seconds,
            duration: built.duration,
            frameRate: project.frameRate)
        let frameImage = try await Self.generateCoverImage(
            generator: generator,
            time: CMTime(seconds: seconds, preferredTimescale: 600))
        // AppKit drawing must stay on the main actor; only the CPU-heavy ImageIO
        // encoding is offloaded to a detached task.
        let imageWithTitle = try Self.imageWithTitleIfNeeded(
            frameImage,
            title: cover.title,
            renderSize: project.renderSize,
            workingColourSpace: project.workingColourSpace)
        let format = cover.format
        return try await Task.detached {
            try Self.encodeCoverImage(imageWithTitle, format: format)
        }.value
    }

    nonisolated static func snappedCoverFrameSeconds(requested: Double,
                                                     duration: Double,
                                                     frameRate: Double) -> Double {
        let fps = frameRate.isFinite && frameRate > 0 ? frameRate : 30
        let frameStep = 1.0 / fps
        let timelineDuration = duration.isFinite ? max(0, duration) : 0
        let lastFrame = max(0, timelineDuration - frameStep)
        let requested = requested.isFinite ? requested : 0
        let clamped = min(max(0, requested), lastFrame)
        let snapped = (clamped / frameStep).rounded() * frameStep
        return min(max(0, snapped), lastFrame)
    }

    /// Bridges the completion-handler frame API into async/await. Kept over the
    /// async `image(at:)` because `generator` is main-actor-isolated here, and
    /// sending it into the `@concurrent` `image(at:)` is a Swift 6 data race.
    private static func generateCoverImage(generator: AVAssetImageGenerator,
                                           time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CoverExportError.imageEncodingFailed)
                }
            }
        }
    }

    @MainActor
    private static func imageWithTitleIfNeeded(_ image: CGImage,
                                               title: CoverTitleDoc?,
                                               renderSize: CGSize,
                                               workingColourSpace: WorkingColourSpace) throws -> CGImage {
        guard let title, !title.text.isEmpty else { return image }
        let width = max(1, Int(renderSize.width.rounded()))
        let height = max(1, Int(renderSize.height.rounded()))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: workingColourSpace.cgColorSpace,
            bitmapInfo: bitmapInfo) else {
            throw CoverExportError.imageEncodingFailed
        }
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        let size = NSSize(width: width, height: height)
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.current = previousContext }
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: image, size: size).draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1)

        let font = NSFont.systemFont(ofSize: max(12, min(title.fontSize, Double(height) * 0.12)),
                                     weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .strokeColor: NSColor.black.withAlphaComponent(0.65),
            .strokeWidth: -3,
        ]
        let textWidth = Double(width) * 0.82
        let textHeight = max(Double(font.pointSize) * 1.35, 44)
        let originX = Double(width) * title.normalizedX - textWidth / 2
        let originY = Double(height) * (1 - title.normalizedY) - textHeight / 2
        NSString(string: title.text).draw(
            in: NSRect(x: originX, y: originY, width: textWidth, height: textHeight),
            withAttributes: attributes)
        guard let cgImage = context.makeImage() else { throw CoverExportError.imageEncodingFailed }
        return cgImage
    }

    nonisolated private static func encodeCoverImage(_ image: CGImage, format: CoverFormat) throws -> Data {
        let type = format.utType
        guard Self.supportsImageDestination(type) else {
            throw CoverExportError.unsupportedFormat(format.displayName)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil) else {
            throw CoverExportError.imageEncodingFailed
        }
        let options: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.92]
            : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CoverExportError.imageEncodingFailed
        }
        return data as Data
    }

    nonisolated private static func supportsImageDestination(_ type: UTType) -> Bool {
        guard let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] else {
            return false
        }
        return identifiers.contains(type.identifier)
    }

    /// Generates cover image data for inclusion in a `.lcbundle` save. A cover
    /// generation error should not block the bundle save, but the caller must
    /// surface the warning after the save succeeds.
    func makeCoverBundleData() async -> (data: ProjectBundle.CoverBundleData?, warning: String?) {
        guard project.coverFrame != nil else { return (nil, nil) }
        do {
            let data = try await makeCoverImageData()
            let format = project.coverFrame?.format ?? .png
            return (ProjectBundle.CoverBundleData(
                imageData: data,
                fileExtension: format.fileExtension), nil)
        } catch {
            return (nil, "Could not generate bundle cover: \(error.localizedDescription)")
        }
    }
}

private enum CoverExportError: LocalizedError {
    case emptyProject
    case unsupportedFormat(String)
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyProject:
            "Nothing to export - the timeline is empty."
        case .unsupportedFormat(let format):
            "\(format) cover export is not available on this Mac."
        case .imageEncodingFailed:
            "Could not encode the cover image."
        }
    }
}

private extension CoverFormat {
    nonisolated var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}
