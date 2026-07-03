import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore

nonisolated final class CaptureManifestFileWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.localcutstudio.capture.manifest")
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        close()
    }

    func append(_ record: CaptureManifestRecord) throws {
        let line = try CaptureManifest.lineData(for: record)
        try queue.sync {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        }
    }

    func close() {
        queue.sync {
            try? handle.close()
        }
    }
}

nonisolated final class ContinuousCaptureWriter: @unchecked Sendable {
    let source: CaptureSourceDescriptor
    private let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let sessionStartHostTimeUs: Int64
    private let manifest: CaptureManifestFileWriter
    private let onSustainedBackpressure: (@Sendable (CaptureSourceDescriptor) -> Void)?
    /// Called when new encoded fragment data is available for the replay buffer.
    /// Receives the encoded chunk with data already loaded.
    private let onEncodedChunk: (@Sendable (EncodedChunk) -> Void)?
    private let lock = NSLock()

    /// Roughly two seconds of drops at 30 fps before we warn the user; a single
    /// hiccup shouldn't raise an alarm, sustained loss should.
    private static let sustainedDropThreshold = 60

    private var didStartWriting = false
    private var isFinished = false
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var sampleCount = 0
    private var droppedSamples = 0
    private var didRecordBackpressure = false
    private var didNotifyBackpressure = false
    private var writeStartupError: String?
    private var manifestAppendError: String?
    /// Tracks the last known file size for fragment boundary detection.
    private var lastKnownFileSize: UInt64 = 0
    /// The PTS of the first sample in the current fragment being accumulated.
    private var currentFragmentStartPTS: CMTime?

    init(source: CaptureSourceDescriptor,
         outputURL: URL,
         mediaType: AVMediaType,
         outputSettings: [String: Any],
         fragmentInterval: CMTime,
         sessionStartHostTimeUs: Int64,
         manifest: CaptureManifestFileWriter,
         onSustainedBackpressure: (@Sendable (CaptureSourceDescriptor) -> Void)? = nil,
         onEncodedChunk: (@Sendable (EncodedChunk) -> Void)? = nil) throws {
        self.source = source
        self.outputURL = outputURL
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        self.writer.movieFragmentInterval = fragmentInterval
        self.input = AVAssetWriterInput(mediaType: mediaType, outputSettings: outputSettings)
        self.input.expectsMediaDataInRealTime = true
        self.sessionStartHostTimeUs = sessionStartHostTimeUs
        self.manifest = manifest
        self.onSustainedBackpressure = onSustainedBackpressure
        self.onEncodedChunk = onEncodedChunk

        guard writer.canAdd(input) else {
            throw CaptureEngineError.writerRejectedInput(source.displayName)
        }
        writer.add(input)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        appendLocked(sampleBuffer)
    }

    private func appendLocked(_ sampleBuffer: CMSampleBuffer) {
        // Once finalized (or a fatal writer failure occurred) discard any
        // late-arriving buffers; appending to a finished/failed writer crashes.
        guard !isFinished else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, !pts.isIndefinite else { return }

        if !didStartWriting {
            guard writer.startWriting() else {
                let reason = writer.error?.localizedDescription ?? "writer.startWriting failed"
                writeStartupError = reason
                recordBackpressure(reason: reason)
                // A failed AVAssetWriter cannot recover; stop attempting on
                // every subsequent frame.
                isFinished = true
                return
            }
            writer.startSession(atSourceTime: pts)
            firstPresentationTime = pts
            didStartWriting = true
        }

        guard input.isReadyForMoreMediaData else {
            droppedSamples += 1
            recordBackpressure(reason: "writer input was not ready")
            notifySustainedBackpressureIfNeeded()
            return
        }

        if input.append(sampleBuffer) {
            sampleCount += 1
            lastPresentationTime = pts
            checkForFragmentFlush(currentPTS: pts)
        } else {
            droppedSamples += 1
            recordBackpressure(reason: writer.error?.localizedDescription ?? "append failed")
            notifySustainedBackpressureIfNeeded()
        }
    }

    private func notifySustainedBackpressureIfNeeded() {
        // Fire once per source when drops cross the sustained threshold so the
        // UI can warn the user instead of silently producing a gapped capture.
        guard !didNotifyBackpressure, droppedSamples >= Self.sustainedDropThreshold else { return }
        didNotifyBackpressure = true
        onSustainedBackpressure?(source)
    }

    private func recordBackpressure(reason: String) {
        guard !didRecordBackpressure else { return }
        didRecordBackpressure = true
        let atUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        let record = CaptureBackpressureRecord(
            sourceID: source.id,
            atUs: atUs,
            droppedSamples: max(1, droppedSamples),
            reason: reason)
        do {
            try manifest.append(.backpressure(record))
        } catch {
            manifestAppendError = error.localizedDescription
        }
    }

    func finish() async throws -> CaptureSourceEndedRecord {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            // Block any concurrent late buffers before finalizing the input.
            isFinished = true

            guard didStartWriting else {
                if let message = writeStartupError {
                    writer.cancelWriting()
                    lock.unlock()
                    continuation.resume(throwing: CaptureEngineError.writerStartFailed(message))
                    return
                }
                let record = endedRecord(durationUs: 0)
                lock.unlock()
                continuation.resume(returning: record)
                return
            }

            input.markAsFinished()
            let record = endedRecord(durationUs: durationUs())
            lock.unlock()
            writer.finishWriting {
                if let error = self.writer.error {
                    continuation.resume(throwing: CaptureEngineError.writerFinishFailed(error.localizedDescription))
                } else if let manifestAppendError = self.manifestAppendError {
                    continuation.resume(throwing: CaptureEngineError.manifestWriteFailed(manifestAppendError))
                } else {
                    continuation.resume(returning: record)
                }
            }
        }
    }

    private func endedRecord(durationUs: Int64) -> CaptureSourceEndedRecord {
        CaptureSourceEndedRecord(
            sourceID: source.id,
            atUs: CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock())),
            durationUs: durationUs,
            timelineStartUs: timelineStartUs(),
            sampleCount: sampleCount)
    }

    private func durationUs() -> Int64 {
        guard let firstPresentationTime, let lastPresentationTime else { return 0 }
        return CaptureManifest.microseconds(from: lastPresentationTime - firstPresentationTime)
    }

    private func timelineStartUs() -> Int64 {
        guard let firstPresentationTime else { return source.timelineStartUs }
        let firstUs = CaptureManifest.microseconds(from: firstPresentationTime)
        return max(0, firstUs - sessionStartHostTimeUs)
    }

    /// Checks if the AVAssetWriter flushed a new fragment to disk. If so,
    /// reads the new bytes and emits an `EncodedChunk` via the callback.
    ///
    /// `AVAssetWriter.movieFragmentInterval` causes the writer to flush
    /// encoded data to disk at the configured interval. By tracking the file
    /// size, we detect when a fragment boundary was crossed and capture the
    /// newly-written encoded bytes.
    private func checkForFragmentFlush(currentPTS: CMTime) {
        guard let onEncodedChunk else { return }

        // Track fragment start PTS.
        if currentFragmentStartPTS == nil {
            currentFragmentStartPTS = currentPTS
        }

        // Check file size. If it grew, a fragment may have been flushed.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              let fileSize = attrs[.size] as? UInt64 else { return }

        let newSize = fileSize
        guard newSize > lastKnownFileSize else { return }

        // New bytes were written. Read them as a chunk.
        let newBytesCount = Int(newSize - lastKnownFileSize)
        guard newBytesCount > 0 else { return }

        // Read the new bytes from the file. This is safe because
        // AVAssetWriter writes synchronously during append(), so the data
        // is fully flushed by the time we read here.
        guard let handle = try? FileHandle(forReadingFrom: outputURL) else { return }
        defer { try? handle.close() }

        handle.seek(toFileOffset: lastKnownFileSize)
        guard let data = try? handle.read(upToCount: newBytesCount), data.count == newBytesCount else {
            return
        }

        lastKnownFileSize = newSize

        // Create the chunk. The fragment duration is approximate (based on
        // the fragment interval); the exact duration isn't critical for the
        // replay buffer since the PTS/byte-range tracking is what matters.
        let fragmentPTS = currentFragmentStartPTS ?? currentPTS
        let fragmentDuration = currentPTS - fragmentPTS
        let chunk = EncodedChunk(
            presentationTimeStamp: fragmentPTS,
            decodeTimeStamp: fragmentPTS,
            duration: fragmentDuration.isValid && fragmentDuration.seconds > 0
                ? fragmentDuration
                : CMTime(seconds: 1.0, preferredTimescale: 600),
            byteSize: newBytesCount,
            isKeyframe: true, // movieFragmentInterval fragments start with keyframes
            sourceID: source.id,
            data: data)

        onEncodedChunk(chunk)

        // Start tracking the next fragment.
        currentFragmentStartPTS = currentPTS
    }
}
