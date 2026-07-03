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
    /// Groups chunks by source file, then uses AVAssetReader to extract
    /// each source's time range and writes them into the output via
    /// AVAssetWriter with proper movie headers.
    static func finalize(chunks: [EncodedChunk],
                         outputURL: URL) async throws -> CMTime {
        guard !chunks.isEmpty else {
            throw ReplayBufferError.noChunks
        }

        // Group chunks by source file and compute the overall time range.
        let grouped = Dictionary(grouping: chunks, by: \.sourceFileURL)
        let allPTS = chunks.map(\.presentationTimeStamp)
        let overallStart = allPTS.min() ?? .zero
        let overallEnd = chunks.map(\.endTime).max() ?? .zero
        let overallDuration = overallEnd - overallStart

        // Create the output writer.
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        // Process each source file and collect reader/track info.
        struct SourceReader {
            let reader: AVAssetReader
            let outputs: [AVAssetReaderTrackOutput]
            let inputs: [AVAssetWriterInput]
        }
        var sourceReaders: [SourceReader] = []

        for (sourceURL, sourceChunks) in grouped.sorted(by: { $0.key.path < $1.key.path }) {
            let sortedChunks = sourceChunks.sorted { $0.presentationTimeStamp < $1.presentationTimeStamp }
            guard let firstChunk = sortedChunks.first,
                  let lastChunk = sortedChunks.last else { continue }

            let spanStart = firstChunk.presentationTimeStamp
            let spanEnd = lastChunk.endTime
            let spanDuration = spanEnd - spanStart
            guard spanDuration.seconds > 0 else { continue }

            let asset = AVURLAsset(url: sourceURL)
            let isReadable = (try? await asset.load(.isReadable)) ?? false
            guard isReadable else {
                log.warning("Source file not readable: \(sourceURL.lastPathComponent)")
                continue
            }

            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                log.warning("Could not create reader for \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                continue
            }

            reader.timeRange = CMTimeRange(start: spanStart, duration: spanDuration)

            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let tracks = videoTracks + audioTracks
            var outputs: [AVAssetReaderTrackOutput] = []
            var inputs: [AVAssetWriterInput] = []

            for track in tracks {
                let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(readerOutput) else { continue }
                reader.add(readerOutput)

                let writerInput = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil)
                guard writer.canAdd(writerInput) else { continue }
                writer.add(writerInput)

                outputs.append(readerOutput)
                inputs.append(writerInput)
            }

            if !outputs.isEmpty {
                sourceReaders.append(SourceReader(reader: reader, outputs: outputs, inputs: inputs))
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

        // Process all sources sequentially. Each source's samples are
        // written in order, which preserves temporal alignment.
        for source in sourceReaders {
            guard source.reader.startReading() else {
                log.warning("Could not start reader: \(source.reader.error?.localizedDescription ?? "unknown")")
                continue
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let group = DispatchGroup()
                let writerQueue = DispatchQueue(label: "com.localcutstudio.replay.writer")

                for (readerOutput, writerInput) in zip(source.outputs, source.inputs) {
                    group.enter()
                    writerInput.requestMediaDataWhenReady(on: writerQueue) {
                        while writerInput.isReadyForMoreMediaData {
                            guard let sample = readerOutput.copyNextSampleBuffer() else {
                                writerInput.markAsFinished()
                                group.leave()
                                return
                            }
                            if !writerInput.append(sample) {
                                writerInput.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                    }
                }

                group.notify(queue: writerQueue) {
                    continuation.resume()
                }
            }
        }

        // Finish writing.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return overallDuration
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
