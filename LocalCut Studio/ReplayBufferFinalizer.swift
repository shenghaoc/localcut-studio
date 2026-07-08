import Foundation
import AVFoundation
import CoreMedia
import os
import LocalCutCore

/// Finalises encoded chunks from the replay buffer into a playable `.mov`
/// file using AVAssetReader on the original recording source files.
///
/// Each chunk records the source file URL and time range. The finalizer
/// uses AVAssetReader to extract the correct time range from each source,
/// producing output with proper ftyp/moov headers.
enum ReplayBufferFinalizer {

    private static let log = Logger(
        subsystem: "com.localcutstudio.replay",
        category: "finalizer")

    /// Finalises the given chunks into a playable fragmented `.mov`.
    ///
    /// Finalises one source file's chunks by using AVAssetReader to extract
    /// the requested source time range and AVAssetWriter to write proper
    /// movie headers. Multi-source replay batches are split by
    /// `ReplayBufferManager` before reaching this boundary.
    static func finalize(chunks: [EncodedChunk],
                         outputURL: URL) async throws -> CMTime {
        guard !chunks.isEmpty else {
            throw ReplayBufferError.noChunks
        }

        // Group chunks by source file and build extraction plans. Chunk
        // timestamps are session-relative; sourceTimeStamp is the time range
        // inside the individual writer output file.
        let grouped = Dictionary(grouping: chunks, by: \.sourceFileURL)
        guard grouped.count == 1 else {
            throw ReplayBufferError.finalizeFailed("Replay finalizer expects a single source file per output.")
        }

        struct SourcePlan {
            let sourceURL: URL
            let sourceStart: CMTime
            let sourceEnd: CMTime
            let timelineOffset: CMTime

            var timelineStart: CMTime { sourceStart + timelineOffset }
            var timelineEnd: CMTime { sourceEnd + timelineOffset }
            var sourceDuration: CMTime { sourceEnd - sourceStart }
        }

        var plans: [SourcePlan] = []

        for (sourceURL, sourceChunks) in grouped.sorted(by: { $0.key.path < $1.key.path }) {
            let sortedChunks = sourceChunks.sorted { $0.sourceTimeStamp < $1.sourceTimeStamp }
            guard let firstChunk = sortedChunks.first,
                  let lastChunk = sortedChunks.last else { continue }

            var sourceStart = firstChunk.sourceTimeStamp
            let sourceEnd = lastChunk.sourceTimeStamp + lastChunk.duration
            guard sourceEnd > sourceStart else { continue }

            let asset = AVURLAsset(url: sourceURL)
            if sourceChunks.contains(where: { $0.mediaType == .video }) {
                let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                if let videoTrack = videoTracks.first {
                    sourceStart = await alignedVideoStart(
                        asset: asset,
                        track: videoTrack,
                        requestedStart: sourceStart)
                }
            }

            plans.append(SourcePlan(
                sourceURL: sourceURL,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                timelineOffset: firstChunk.presentationTimeStamp - firstChunk.sourceTimeStamp))
        }

        guard !plans.isEmpty else {
            throw ReplayBufferError.finalizeFailed("No valid source ranges found.")
        }

        let outputStart = plans.map(\.timelineStart).min() ?? .zero
        let outputEnd = plans.map(\.timelineEnd).max() ?? .zero
        let overallDuration = outputEnd - outputStart

        // Create the output writer.
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let writerBox = WriterBox(writer)

        // Process each source file and collect reader/track info.
        var sourceReaders: [SourceReader] = []

        for plan in plans {
            let asset = AVURLAsset(url: plan.sourceURL)
            let isReadable = (try? await asset.load(.isReadable)) ?? false
            guard isReadable else {
                log.warning("Source file not readable: \(plan.sourceURL.lastPathComponent)")
                continue
            }

            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                log.warning("Could not create reader for \(plan.sourceURL.lastPathComponent): \(error.localizedDescription)")
                continue
            }

            reader.timeRange = CMTimeRange(start: plan.sourceStart, duration: plan.sourceDuration)

            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let tracks = Array(videoTracks.prefix(1)) + audioTracks
            var pipes: [TrackPipe] = []

            for track in tracks {
                let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(readerOutput) else { continue }
                reader.add(readerOutput)

                let writerInput = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil)
                guard writer.canAdd(writerInput) else { continue }
                writer.add(writerInput)

                pipes.append(TrackPipe(readerOutput: readerOutput, writerInput: writerInput))
            }

            if !pipes.isEmpty {
                sourceReaders.append(SourceReader(
                    reader: reader,
                    pipes: pipes,
                    timelineOffset: plan.timelineOffset))
            }
        }

        guard !sourceReaders.isEmpty else {
            throw ReplayBufferError.finalizeFailed("No valid tracks found in source files.")
        }

        // Start the writer session.
        guard writer.startWriting() else {
            throw ReplayBufferError.writerStartFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        // Start all readers first to allow concurrent, interleaved writing.
        for source in sourceReaders {
            guard source.reader.startReading() else {
                log.warning("Could not start reader: \(source.reader.error?.localizedDescription ?? "unknown")")
                continue
            }
        }

        // Process all pipes concurrently across all sources to maintain
        // proper interleaving for AVAssetWriter.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let writerQueue = DispatchQueue(label: "com.localcutstudio.replay.writer")

            for source in sourceReaders {
                guard source.reader.status == .reading else { continue }
                for pipe in source.pipes {
                    group.enter()
                    pipe.writerInput.requestMediaDataWhenReady(on: writerQueue) {
                        while pipe.writerInput.isReadyForMoreMediaData {
                            guard let sample = pipe.readerOutput.copyNextSampleBuffer() else {
                                pipe.writerInput.markAsFinished()
                                group.leave()
                                return
                            }
                            let rebased = sampleByRebasing(
                                sample,
                                timelineOffset: source.timelineOffset,
                                outputStart: outputStart) ?? sample
                            if !pipe.writerInput.append(rebased) {
                                pipe.writerInput.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                    }
                }
            }

            group.notify(queue: writerQueue) {
                continuation.resume()
            }
        }

        // Finish writing.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerBox.writer.finishWriting {
                if let error = writerBox.writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return overallDuration
    }

    private struct SourceReader {
        let reader: AVAssetReader
        let pipes: [TrackPipe]
        let timelineOffset: CMTime
    }

    /// `@unchecked Sendable`: queue-confined wrapper for the non-`Sendable`
    /// `AVAssetReaderTrackOutput` + `AVAssetWriterInput` pair. Each pipe is
    /// accessed only from `requestMediaDataWhenReady(on: writerQueue)` pump
    /// callbacks on the same serial `writerQueue`.
    nonisolated private final class TrackPipe: @unchecked Sendable {
        let readerOutput: AVAssetReaderTrackOutput
        let writerInput: AVAssetWriterInput

        init(readerOutput: AVAssetReaderTrackOutput,
             writerInput: AVAssetWriterInput) {
            self.readerOutput = readerOutput
            self.writerInput = writerInput
        }
    }

    /// `@unchecked Sendable`: immutable wrapper for non-`Sendable` `AVAssetWriter`.
    nonisolated private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter

        init(_ writer: AVAssetWriter) {
            self.writer = writer
        }
    }

    nonisolated private static func alignedVideoStart(asset: AVAsset,
                                                       track: AVAssetTrack,
                                                       requestedStart: CMTime) async -> CMTime {
        guard requestedStart > .zero else { return requestedStart }
        // Limit the scan window to 10 seconds before requestedStart to
        // avoid a linear scan from .zero on long recordings.
        let lookback = CMTime(seconds: 10, preferredTimescale: 600)
        let scanStart = max(.zero, requestedStart - lookback)
        do {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: scanStart, end: requestedStart)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return requestedStart }
            reader.add(output)
            guard reader.startReading() else { return requestedStart }

            var latestSync: CMTime?
            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts <= requestedStart, KeyframeDetector.isKeyframe(sample) {
                    latestSync = pts
                }
            }
            return latestSync ?? requestedStart
        } catch {
            return requestedStart
        }
    }

    nonisolated private static func sampleByRebasing(_ sample: CMSampleBuffer,
                                                     timelineOffset: CMTime,
                                                     outputStart: CMTime) -> CMSampleBuffer? {
        var timingCount: CMItemCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount)
        guard countStatus == noErr, timingCount > 0 else { return nil }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid),
            count: Int(timingCount))
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: timingCount,
            arrayToFill: &timing,
            entriesNeededOut: &timingCount)
        guard timingStatus == noErr else { return nil }

        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp =
                    timing[index].presentationTimeStamp + timelineOffset - outputStart
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp =
                    timing[index].decodeTimeStamp + timelineOffset - outputStart
            }
        }

        var output: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: timingCount,
            sampleTimingArray: &timing,
            sampleBufferOut: &output)
        guard copyStatus == noErr else { return nil }
        return output
    }
}

// MARK: - Errors

enum ReplayBufferError: LocalizedError {
    case noChunks
    case chunkDataMissing(UUID)
    case readerStartFailed(String)
    case writerStartFailed(String)
    case finalizeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noChunks:
            "No chunks available for save."
        case .chunkDataMissing(let id):
            "Chunk \(id.uuidString.prefix(8))… has no data loaded."
        case .readerStartFailed(let reason):
            "Could not read replay data: \(reason)"
        case .writerStartFailed(let reason):
            "Could not write replay file: \(reason)"
        case .finalizeFailed(let reason):
            "Could not finalise replay: \(reason)"
        }
    }
}
