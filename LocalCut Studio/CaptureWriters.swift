import Foundation
import AVFoundation
import CoreMedia
import os
import LocalCutCore

/// `@unchecked Sendable`: `FileHandle` mutations are serialised on a private
/// `DispatchQueue`.
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

/// `@unchecked Sendable`: writer state (`didStartWriting`, `isFinished`,
/// timing, sample counts) is protected by `lock`; `AVAssetWriter` and
/// `AVAssetWriterInput` are non-`Sendable` framework objects.
nonisolated final class ContinuousCaptureWriter: @unchecked Sendable {
    let source: CaptureSourceDescriptor
    private let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let mediaType: AVMediaType
    private let sessionStartHostTimeUs: Int64
    private let manifest: CaptureManifestFileWriter
    private let onSustainedBackpressure: (@Sendable (CaptureSourceDescriptor) -> Void)?
    /// Called when a new sample boundary is available for the replay buffer.
    private let onEncodedChunk: (@Sendable (EncodedChunk) -> Void)?
    private let lock = OSAllocatedUnfairLock(initialState: ())

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
        self.mediaType = mediaType
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
        lock.withLockUnchecked { _ in appendLocked(sampleBuffer) }
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
            emitReplayChunk(for: sampleBuffer, presentationTime: pts)
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
            enum FinishAction {
                case cancelAndThrow(Error)
                case `return`(CaptureSourceEndedRecord)
                case finishWriting(CaptureSourceEndedRecord)
            }
            let action = lock.withLock { _ -> FinishAction in
                // Block any concurrent late buffers before finalizing the input.
                isFinished = true

                guard didStartWriting else {
                    if let message = writeStartupError {
                        return .cancelAndThrow(CaptureEngineError.writerStartFailed(message))
                    }
                    return .return(endedRecord(durationUs: 0))
                }

                input.markAsFinished()
                return .finishWriting(endedRecord(durationUs: durationUs()))
            }

            switch action {
            case .cancelAndThrow(let error):
                writer.cancelWriting()
                continuation.resume(throwing: error)
            case .return(let record):
                continuation.resume(returning: record)
            case .finishWriting(let record):
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

    /// Emits a replay index chunk for the appended sample. The timestamp used
    /// for save-span selection is session-relative; the source timestamp is the
    /// time range AVAssetReader needs inside this writer's output file.
    private func emitReplayChunk(for sampleBuffer: CMSampleBuffer,
                                 presentationTime pts: CMTime) {
        guard let onEncodedChunk else { return }
        guard let firstPresentationTime else { return }

        let duration = sampleDuration(for: sampleBuffer)
        let sourcePTS = pts - firstPresentationTime
        let timelinePTS = sessionRelativeTime(from: pts)
        let decodeTime = KeyframeDetector.decodeTimeStamp(sampleBuffer)
        let timelineDTS = decodeTime.isValid ? sessionRelativeTime(from: decodeTime) : timelinePTS
        let type: EncodedChunkMediaType = mediaType == .audio ? .audio : .video
        // Audio is always independently decodable. For video, raw capture
        // frames lack sync-sample attachments so KeyframeDetector would
        // treat every frame as a keyframe. Mark video as non-keyframe;
        // the finalizer's alignedVideoStart finds the actual sync sample.
        let isSyncSample = type == .audio
        let byteSize = encodedByteEstimate(for: sampleBuffer, duration: duration)

        let chunk = EncodedChunk(
            presentationTimeStamp: timelinePTS,
            decodeTimeStamp: timelineDTS,
            sourceTimeStamp: sourcePTS,
            duration: duration,
            byteSize: byteSize,
            isKeyframe: isSyncSample,
            mediaType: type,
            sourceID: source.id,
            sourceFileURL: outputURL)

        onEncodedChunk(chunk)
    }

    private func sampleDuration(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, duration > .zero {
            return duration
        }
        if mediaType == .video, let frameRate = source.frameRate, frameRate > 0 {
            return CMTime(seconds: 1.0 / frameRate, preferredTimescale: 600)
        }
        if mediaType == .audio,
           let sampleRate = source.sampleRate,
           sampleRate > 0 {
            let samples = max(1, CMSampleBufferGetNumSamples(sampleBuffer))
            return CMTime(
                seconds: Double(samples) / sampleRate,
                preferredTimescale: 600)
        }
        return CMTime(value: 1, timescale: 600)
    }

    private func sessionRelativeTime(from time: CMTime) -> CMTime {
        let timeUs = CaptureManifest.microseconds(from: time)
        return CMTime(
            value: max(0, timeUs - sessionStartHostTimeUs),
            timescale: 1_000_000)
    }

    private func encodedByteEstimate(for sampleBuffer: CMSampleBuffer,
                                     duration: CMTime) -> Int {
        if mediaType == .video,
           let frameRate = source.frameRate,
           frameRate > 0,
           let bitrate = videoBitrateFromInputSettings() {
            return max(1, Int(Double(bitrate) / 8.0 / frameRate))
        }
        if mediaType == .audio,
           duration.seconds.isFinite,
           let bitrate = audioBitrateFromInputSettings() {
            return max(1, Int(Double(bitrate) / 8.0 * max(0, duration.seconds)))
        }
        return max(1, KeyframeDetector.byteSize(sampleBuffer))
    }

    private func videoBitrateFromInputSettings() -> Int? {
        guard let properties = input.outputSettings?[AVVideoCompressionPropertiesKey] as? [String: Any] else {
            return nil
        }
        return properties[AVVideoAverageBitRateKey] as? Int
    }

    private func audioBitrateFromInputSettings() -> Int? {
        input.outputSettings?[AVEncoderBitRateKey] as? Int
    }
}
