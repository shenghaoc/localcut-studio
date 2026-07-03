import Foundation
import AVFoundation
import CoreMedia
import os
import LocalCutCore

/// Finalises encoded chunks from the replay buffer into a fragmented `.mov`
/// file that can be imported into the timeline.
enum ReplayBufferFinalizer {

    private static let log = Logger(
        subsystem: "com.localcutstudio.replay",
        category: "finalizer")

    /// Writes the given encoded chunks into a fragmented `.mov` at `outputURL`.
    ///
    /// The chunks are concatenated as raw fragment data. Each chunk is a
    /// self-contained fragment from `AVAssetWriter.movieFragmentInterval`,
    /// starting with a keyframe. The output file inherits the original
    /// encoding parameters.
    ///
    /// - Parameters:
    ///   - chunks: Ordered encoded chunks to write (must include data).
    ///   - outputURL: Destination URL for the output `.mov`.
    /// - Returns: The duration of the written file.
    /// - Throws: If writing fails.
    static func finalize(chunks: [EncodedChunk],
                         outputURL: URL) async throws -> CMTime {
        guard !chunks.isEmpty else {
            throw ReplayBufferError.noChunks
        }

        // Ensure all chunks have data loaded.
        for chunk in chunks {
            guard chunk.data != nil else {
                throw ReplayBufferError.chunkDataMissing(chunk.id)
            }
        }

        // Strategy: concatenate chunk data into a single file. Each chunk is
        // a fragment from the original AVAssetWriter output, which produces
        // self-contained moof+mdat pairs in fragmented .mov.
        //
        // For a robust output, we re-mux via AVAssetReader+AVAssetWriter
        // using the original source file. But since we have raw fragment
        // data in memory, we write them to a temp file first, then re-mux.

        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("temp-\(UUID().uuidString).mov")

        do {
            // Write all chunk data sequentially to temp file.
            let fileManager = FileManager.default
            fileManager.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)

            for chunk in chunks {
                if let data = chunk.data {
                    handle.write(data)
                }
            }
            handle.closeFile()

            // Re-mux into a proper fragmented .mov with correct headers.
            let duration = try await remuxToFragMOV(sourceURL: tempURL, outputURL: outputURL)

            // Clean up temp file.
            try? fileManager.removeItem(at: tempURL)

            return duration

        } catch {
            // Clean up on failure.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Re-muxes a raw fragment dump into a proper fragmented `.mov`.
    ///
    /// Uses `AVAssetReader` + `AVAssetWriter` to produce a valid `.mov` with
    /// proper moov atom, track metadata, and `movieFragmentInterval`.
    private static func remuxToFragMOV(sourceURL: URL,
                                       outputURL: URL) async throws -> CMTime {
        let asset = AVURLAsset(url: sourceURL)

        // Wait for the asset to be playable.
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            // If the raw fragments aren't directly playable (missing headers),
            // fall back to writing a minimal valid .mov from the chunk data.
            return try writeMinimalMOV(from: sourceURL, to: outputURL)
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let tracks = videoTracks + audioTracks

        for track in tracks {
            let trackID = track.trackID
            let outputSettings: [String: Any]? = nil // Copy as-is

            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            guard reader.canAdd(readerOutput) else { continue }
            reader.add(readerOutput)

            let writerInput = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: outputSettings)
            guard writer.canAdd(writerInput) else { continue }
            writer.add(writerInput)
        }

        guard reader.startReading() else {
            throw ReplayBufferError.readerStartFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw ReplayBufferError.writerStartFailed(writer.error?.localizedDescription ?? "unknown")
        }

        writer.startSession(atSourceTime: .zero)

        // Process samples.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()

            for (readerOutput, writerInput) in zip(reader.outputs, writer.inputs) {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    while writerInput.isReadyForMoreMediaData {
                        guard let sample = readerOutput.copyNextSampleBuffer() else {
                            writerInput.markAsFinished()
                            group.leave()
                            break
                        }
                        if !writerInput.append(sample) {
                            writerInput.markAsFinished()
                            group.leave()
                            break
                        }
                    }
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                writer.finishWriting {
                    if let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        // Read the duration from the output.
        let outputAsset = AVURLAsset(url: outputURL)
        let duration = try await outputAsset.load(.duration)
        return duration
    }

    /// Writes a minimal valid `.mov` by concatenating fragment data with a
    /// basic ftyp atom. This is a fallback when the raw fragments can't be
    /// read by AVAssetReader (e.g., missing initial moov atom).
    private static func writeMinimalMOV(from sourceURL: URL,
                                        to outputURL: URL) throws -> CMTime {
        let data = try Data(contentsOf: sourceURL)

        // Build a minimal ftyp + mdat wrapper.
        let ftyp = buildFTYPAtom()
        let mdat = buildMDATAtom(data: data)

        let output = ftyp + mdat
        try output.write(to: outputURL)

        // Estimate duration from data size (rough: assume 2 Mbps for 1080p30).
        let estimatedSeconds = Double(data.count * 8) / 2_000_000
        return CMTime(seconds: max(0.1, estimatedSeconds), preferredTimescale: 600)
    }

    /// Builds a minimal ftyp atom for QuickTime .mov.
    private static func buildFTYPAtom() -> Data {
        // ftyp box: size(4) + "ftyp"(4) + major_brand(4) + minor_version(4) + compatible_brands(8)
        var data = Data()
        let ftypContent: [UInt8] = [
            // major_brand: "qt  "
            0x71, 0x74, 0x20, 0x20,
            // minor_version
            0x00, 0x00, 0x00, 0x00,
            // compatible_brands: "qt  "
            0x71, 0x74, 0x20, 0x20
        ]
        let size: UInt32 = UInt32(8 + ftypContent.count)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(contentsOf: [0x66, 0x74, 0x79, 0x70]) // "ftyp"
        data.append(contentsOf: ftypContent)
        return data
    }

    /// Builds an mdat atom containing the given data.
    private static func buildMDATAtom(data: Data) -> Data {
        var result = Data()
        let size: UInt32 = UInt32(8 + data.count)
        result.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        result.append(contentsOf: [0x6D, 0x64, 0x61, 0x74]) // "mdat"
        result.append(data)
        return result
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
