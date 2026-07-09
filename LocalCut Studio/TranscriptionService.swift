import Foundation
import AVFoundation
import Speech
import NaturalLanguage
import LocalCutCore

// MARK: - Transcription Error

/// Typed errors from the transcription pipeline.
enum TranscriptionError: LocalizedError {
    case authorizationDenied
    case authorizationRestricted
    case authorizationNotDetermined
    case localeUnavailable
    case onDeviceUnavailable
    case noAudioTrack
    case drmProtected
    case unsupportedFormat(String)
    case extractionFailed(String)
    case recognitionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: "Speech recognition access was denied."
        case .authorizationRestricted: "Speech recognition is restricted."
        case .authorizationNotDetermined: "Speech recognition permission not yet requested."
        case .localeUnavailable: "Speech recognition is not available for the selected language."
        case .onDeviceUnavailable: "On-device speech recognition is not supported for this language."
        case .noAudioTrack: "The selected clip has no audio track."
        case .drmProtected: "The audio is DRM-protected and cannot be transcribed."
        case .unsupportedFormat(let detail): "Unsupported audio format: \(detail)"
        case .extractionFailed(let detail): "Audio extraction failed: \(detail)"
        case .recognitionFailed(let detail): "Speech recognition failed: \(detail)"
        case .cancelled: "Transcription was cancelled."
        }
    }
}

// MARK: - VAD Segment

/// A segment of audio detected as containing speech.
nonisolated struct VADSegment: Equatable, Sendable {
    /// Offset from the start of the audio buffer.
    let start: CMTime
    let duration: CMTime

    nonisolated var end: CMTime { start + duration }
}

// MARK: - Recognition Window

/// One window of audio to submit to the recognizer.
nonisolated struct RecognitionWindow: Equatable, Sendable {
    let index: Int
    let windowOffsetInClip: CMTime
    let windowDuration: CMTime
    let sourceStart: CMTime
    let clipTimelineStart: CMTime
}

// MARK: - Raw Transcription Segment

/// A segment returned by the Speech recognizer before timeline mapping.
nonisolated struct RawTranscriptionSegment: Sendable {
    let timestamp: CMTime
    let duration: CMTime
    let substring: String
    let words: [RawWordTiming]
}

nonisolated struct RawWordTiming: Sendable {
    let timestamp: CMTime
    let duration: CMTime
    let word: String
}

// MARK: - Transcription Configuration

/// Tunable parameters for the VAD pre-pass.
nonisolated struct VADConfiguration: Sendable {
    /// Energy threshold to open a speech segment (dBFS). Lower = more sensitive.
    let openThreshold: Float
    /// Energy threshold to close a speech segment (dBFS). Must be < openThreshold for hysteresis.
    let closeThreshold: Float
    /// Minimum duration of a speech segment to keep (seconds).
    let minimumSpeechDuration: Double
    /// Minimum duration of silence to split segments (seconds).
    let minimumSilenceDuration: Double
    /// Padding added before and after each speech segment (seconds).
    let padding: Double

    nonisolated static let `default` = VADConfiguration(
        openThreshold: -40.0,
        closeThreshold: -50.0,
        minimumSpeechDuration: 0.3,
        minimumSilenceDuration: 0.3,
        padding: 0.1
    )
}

/// Configuration for windowed recognition.
nonisolated struct WindowingConfiguration: Sendable {
    /// Maximum window duration in seconds.
    let maxWindowDuration: Double
    /// Overlap stride between adjacent windows in seconds.
    let overlapStride: Double

    nonisolated static let `default` = WindowingConfiguration(
        maxWindowDuration: 50.0,
        overlapStride: 2.0
    )
}

// MARK: - Transcription Service

/// Background actor that wraps `SFSpeechRecognizer` for on-device speech recognition.
///
/// All Speech framework calls are isolated to this actor to avoid blocking the main actor.
actor TranscriptionService {

    // MARK: - Availability

    /// Checks whether on-device speech recognition is available for the given locale.
    /// This is the three-step gate: recognizer exists → supports on-device → authorization.
    static func checkAvailability(locale: Locale) async -> TranscriptionAvailability {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unavailableLocale
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .onDeviceUnavailable
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    // MARK: - Locale Selection

    /// Selects the transcription locale using the priority chain:
    /// 1. Explicit user override
    /// 2. Clip asset metadata
    /// 3. System locale fallback
    static func selectLocale(
        userOverride: Locale?,
        assetMetadataLocale: Locale?
    ) -> TranscriptionLocaleChoice {
        if let override = userOverride {
            return TranscriptionLocaleChoice(locale: override, source: .userOverride)
        }
        if let metadata = assetMetadataLocale {
            return TranscriptionLocaleChoice(locale: metadata, source: .assetMetadata)
        }
        return TranscriptionLocaleChoice(locale: Locale.current, source: .systemFallback)
    }

    // MARK: - Audio Extraction

    /// Extracts PCM audio from the given asset for the specified time range.
    /// Returns the audio buffer as AVAudioPCMBuffer in a format suitable for Speech recognition.
    static func extractAudio(
        from asset: AVAsset,
        sourceStart: CMTime,
        duration: CMTime,
        cancellation: CancellationToken
    ) async throws -> AVAudioPCMBuffer {
        guard !cancellation.isCancelled else {
            throw TranscriptionError.cancelled
        }

        // Check for audio track
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw TranscriptionError.noAudioTrack
        }

        // Configure reader
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)

        let timeRange = CMTimeRange(start: sourceStart, duration: duration)
        reader.timeRange = timeRange

        guard reader.startReading() else {
            if let error = reader.error {
                if (error as NSError).domain == AVFoundationErrorDomain {
                    throw TranscriptionError.drmProtected
                }
                throw TranscriptionError.extractionFailed(error.localizedDescription)
            }
            throw TranscriptionError.extractionFailed("Unknown error starting reader")
        }

        // Collect all sample buffers into one contiguous PCM buffer
        var sampleBuffers: [CMSampleBuffer] = []
        while reader.status == .reading {
            guard !cancellation.isCancelled else {
                reader.cancelReading()
                throw TranscriptionError.cancelled
            }
            if let sampleBuffer = output.copyNextSampleBuffer() {
                sampleBuffers.append(sampleBuffer)
            }
        }

        guard reader.status == .completed else {
            if let error = reader.error {
                throw TranscriptionError.extractionFailed(error.localizedDescription)
            }
            throw TranscriptionError.extractionFailed("Reader did not complete")
        }

        // Merge into single buffer
        return try mergeSampleBuffers(sampleBuffers)
    }

    // MARK: - VAD Pre-Pass

    /// Runs energy-based voice activity detection with hysteresis.
    /// Returns segments containing speech.
    static func detectVoiceActivity(
        in buffer: AVAudioPCMBuffer,
        config: VADConfiguration = .default
    ) -> [VADSegment] {
        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        let frameCount = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0, sampleRate > 0 else { return [] }

        // Compute energy in ~20ms windows
        let windowSamples = Int(sampleRate * 0.02)
        var energies: [Float] = []
        var index = 0
        while index < frameCount {
            let end = min(index + windowSamples, frameCount)
            var sum: Float = 0
            for i in index..<end {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(end - index))
            let dbfs = 20 * log10(max(rms, 1e-10))
            energies.append(dbfs)
            index = end
        }

        // Hysteresis-based segmentation
        var segments: [VADSegment] = []
        var inSpeech = false
        var speechStart: Double = 0
        let windowDuration = 1.0 / 50.0  // 20ms windows

        for (i, energy) in energies.enumerated() {
            let time = Double(i) * windowDuration

            if !inSpeech {
                if energy >= config.openThreshold {
                    inSpeech = true
                    speechStart = max(0, time - config.padding)
                }
            } else {
                if energy < config.closeThreshold {
                    let speechEnd = time + config.padding
                    let duration = speechEnd - speechStart
                    if duration >= config.minimumSpeechDuration {
                        segments.append(VADSegment(
                            start: CMTime(seconds: speechStart, preferredTimescale: 600),
                            duration: CMTime(seconds: duration, preferredTimescale: 600)
                        ))
                    }
                    inSpeech = false
                }
            }
        }

        // Close any open segment at the end
        if inSpeech {
            let totalDuration = Double(frameCount) / sampleRate
            let speechEnd = totalDuration + config.padding
            let duration = speechEnd - speechStart
            if duration >= config.minimumSpeechDuration {
                segments.append(VADSegment(
                    start: CMTime(seconds: speechStart, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600)
                ))
            }
        }

        // Merge segments separated by less than minimumSilenceDuration
        return mergeSegments(segments, minimumSilence: config.minimumSilenceDuration)
    }

    // MARK: - Windowed Recognition

    /// Splits audio into windows for recognition, respecting VAD boundaries.
    static func createWindows(
        vadSegments: [VADSegment],
        totalDuration: CMTime,
        clipTimelineStart: CMTime,
        sourceStart: CMTime,
        config: WindowingConfiguration = .default
    ) -> [RecognitionWindow] {
        guard totalDuration > .zero else { return [] }

        let maxDuration = CMTime(seconds: config.maxWindowDuration, preferredTimescale: 600)
        let overlap = CMTime(seconds: config.overlapStride, preferredTimescale: 600)

        // If no VAD segments, create windows from the full duration
        if vadSegments.isEmpty {
            return createFixedWindows(
                totalDuration: totalDuration,
                clipTimelineStart: clipTimelineStart,
                sourceStart: sourceStart,
                maxDuration: maxDuration,
                overlap: overlap
            )
        }

        // Create windows aligned to VAD segments
        var windows: [RecognitionWindow] = []
        var windowIndex = 0

        for segment in vadSegments {
            let segmentEnd = segment.start + segment.duration

            // If this segment fits in the current window, extend it
            if !windows.isEmpty {
                let lastWindow = windows[windows.count - 1]
                let lastEnd = lastWindow.windowOffsetInClip + lastWindow.windowDuration
                if segment.start - lastEnd < overlap {
                    // Extend last window
                    let newDuration = segmentEnd - lastWindow.windowOffsetInClip
                    if newDuration <= maxDuration {
                        windows[windows.count - 1] = RecognitionWindow(
                            index: lastWindow.index,
                            windowOffsetInClip: lastWindow.windowOffsetInClip,
                            windowDuration: newDuration,
                            sourceStart: lastWindow.sourceStart,
                            clipTimelineStart: lastWindow.clipTimelineStart
                        )
                        continue
                    }
                }
            }

            // Create a new window for this segment (with small padding)
            let paddingSeconds = 0.1
            let windowStart = max(.zero, segment.start - CMTime(seconds: paddingSeconds, preferredTimescale: 600))
            let windowEnd = min(totalDuration, segmentEnd + CMTime(seconds: paddingSeconds, preferredTimescale: 600))
            let windowDuration = windowEnd - windowStart

            if windowDuration > maxDuration {
                // Split long segments into multiple windows
                let subWindows = createFixedWindows(
                    totalDuration: windowDuration,
                    clipTimelineStart: clipTimelineStart,
                    sourceStart: sourceStart + windowStart,
                    maxDuration: maxDuration,
                    overlap: overlap
                )
                for var sub in subWindows {
                    sub = RecognitionWindow(
                        index: windowIndex,
                        windowOffsetInClip: windowStart + sub.windowOffsetInClip,
                        windowDuration: sub.windowDuration,
                        sourceStart: sub.sourceStart,
                        clipTimelineStart: clipTimelineStart
                    )
                    windows.append(sub)
                    windowIndex += 1
                }
            } else {
                windows.append(RecognitionWindow(
                    index: windowIndex,
                    windowOffsetInClip: windowStart,
                    windowDuration: windowDuration,
                    sourceStart: sourceStart + windowStart,
                    clipTimelineStart: clipTimelineStart
                ))
                windowIndex += 1
            }
        }

        return windows
    }

    // MARK: - Recognition

    /// Runs speech recognition on a single audio buffer.
    static func recognizeWindow(
        buffer: AVAudioPCMBuffer,
        locale: Locale,
        window: RecognitionWindow,
        cancellation: CancellationToken
    ) async throws -> [RawTranscriptionSegment] {
        guard !cancellation.isCancelled else {
            throw TranscriptionError.cancelled
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.localeUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let lock = NSLock()

            recognizer.recognitionTask(with: request) { result, error in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }

                if let error {
                    hasResumed = true
                    continuation.resume(throwing: TranscriptionError.recognitionFailed(error.localizedDescription))
                    return
                }

                guard let result else {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: [])
                    }
                    return
                }

                if result.isFinal {
                    hasResumed = true
                    let segments = Self.extractSegments(from: result)
                    continuation.resume(returning: segments)
                }
            }
        }
    }

    // MARK: - Stitcher

    /// Stitches recognition results from multiple windows, deduplicating overlap regions.
    static func stitchWindows(
        _ windowResults: [(window: RecognitionWindow, segments: [RawTranscriptionSegment])],
        overlapStride: Double
    ) -> [RawTranscriptionSegment] {
        guard !windowResults.isEmpty else { return [] }
        if windowResults.count == 1 {
            return windowResults[0].segments
        }

        var allSegments: [RawTranscriptionSegment] = []

        for (i, result) in windowResults.enumerated() {
            var segments = result.segments

            if i > 0 {
                // Deduplicate overlap with previous window
                let overlapTime = CMTime(seconds: overlapStride, preferredTimescale: 600)
                segments = deduplicateOverlap(
                    previousSegments: allSegments,
                    currentSegments: segments,
                    overlapDuration: overlapTime
                )
            }

            allSegments.append(contentsOf: segments)
        }

        return allSegments
    }

    // MARK: - Language Verification

    /// Verifies the transcription language using NLLanguageRecognizer.
    /// Returns a warning if the detected language disagrees with the chosen locale.
    static func verifyLanguage(
        text: String,
        chosenLocale: Locale
    ) -> TranscriptionWarning? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else { return nil }

        let detectedLocale = Locale(identifier: detected.rawValue)
        let chosenLanguage = chosenLocale.language.languageCode?.identifier ?? ""
        let detectedLanguage = detectedLocale.language.languageCode?.identifier ?? ""

        guard !chosenLanguage.isEmpty, !detectedLanguage.isEmpty else { return nil }
        guard chosenLanguage != detectedLanguage else { return nil }

        return .languageMismatch(detected: detectedLanguage, chosen: chosenLanguage)
    }

    // MARK: - Timeline Mapping

    /// Maps a raw transcription segment to timeline coordinates using the clip's time remapping.
    static func mapToTimeline(
        segment: RawTranscriptionSegment,
        window: RecognitionWindow,
        clip: Clip
    ) -> (line: CaptionLine, wordTimings: [WordTiming]) {
        // Map segment timestamp to source time
        let sourceTime = clip.sourceStart + window.windowOffsetInClip + segment.timestamp

        // Map through speed evaluator to get clip-local output offset
        let outputOffset = clip.outputOffset(forSourceOffset: sourceTime - clip.sourceStart)

        // Convert to timeline position
        let timelineStart = clip.timelineStart + outputOffset

        // Map duration through speed evaluator
        let sourceEnd = sourceTime + segment.duration
        let outputEndOffset = clip.outputOffset(forSourceOffset: sourceEnd - clip.sourceStart)
        let timelineEnd = clip.timelineStart + outputEndOffset
        let timelineDuration = timelineEnd - timelineStart

        let lineRange = CMTimeRange(start: timelineStart, duration: timelineDuration)

        // Map word timings
        let wordTimings = segment.words.map { word in
            let wordSourceTime = clip.sourceStart + window.windowOffsetInClip + word.timestamp
            let wordOutputOffset = clip.outputOffset(forSourceOffset: wordSourceTime - clip.sourceStart)
            let wordTimelineStart = clip.timelineStart + wordOutputOffset

            let wordSourceEnd = wordSourceTime + word.duration
            let wordOutputEndOffset = clip.outputOffset(forSourceOffset: wordSourceEnd - clip.sourceStart)
            let wordTimelineEnd = clip.timelineStart + wordOutputEndOffset

            return WordTiming(
                range: CMTimeRange(start: wordTimelineStart, duration: wordTimelineEnd - wordTimelineStart),
                word: word.word
            )
        }

        let line = CaptionLine(
            range: lineRange,
            text: segment.substring,
            words: wordTimings.isEmpty ? nil : wordTimings
        )

        return (line: line, wordTimings: wordTimings)
    }

    // MARK: - Full Pipeline

    /// Runs the complete transcription pipeline for a clip.
    static func transcribe(
        request: CaptionTranscriptionRequest,
        asset: AVAsset,
        vadConfig: VADConfiguration = .default,
        windowingConfig: WindowingConfiguration = .default,
        progressHandler: @Sendable (TranscriptionProgress) -> Void,
        cancellation: CancellationToken
    ) async throws -> CaptionTranscriptionProposal {
        guard !cancellation.isCancelled else {
            throw TranscriptionError.cancelled
        }

        // 1. Extract audio
        let audioBuffer = try await extractAudio(
            from: asset,
            sourceStart: request.sourceStart,
            duration: request.duration,
            cancellation: cancellation
        )

        guard !cancellation.isCancelled else {
            throw TranscriptionError.cancelled
        }

        // 2. VAD pre-pass
        let vadSegments = detectVoiceActivity(in: audioBuffer, config: vadConfig)

        // 3. Create windows
        let clip = Clip(
            mediaID: request.clipID,
            sourceStart: request.sourceStart,
            duration: request.duration,
            timelineStart: request.timelineStart,
            speedCurve: request.speedCurve ?? TimeRemapping.identitySpeedCurve
        )

        let windows = createWindows(
            vadSegments: vadSegments,
            totalDuration: request.duration,
            clipTimelineStart: request.timelineStart,
            sourceStart: request.sourceStart,
            config: windowingConfig
        )

        guard !windows.isEmpty else {
            return CaptionTranscriptionProposal(
                warnings: [.noSpeechDetected],
                locale: request.locale,
                sourceClipID: request.clipID
            )
        }

        // 4. Recognize each window
        var windowResults: [(window: RecognitionWindow, segments: [RawTranscriptionSegment])] = []
        var warnings: [TranscriptionWarning] = []

        for (windowIndex, window) in windows.enumerated() {
            guard !cancellation.isCancelled else {
                throw TranscriptionError.cancelled
            }

            progressHandler(TranscriptionProgress(
                currentWindow: windowIndex + 1,
                totalWindows: windows.count
            ))

            // Extract audio for this window
            let windowBuffer = try await extractAudio(
                from: asset,
                sourceStart: window.sourceStart,
                duration: window.windowDuration,
                cancellation: cancellation
            )

            let segments = try await recognizeWindow(
                buffer: windowBuffer,
                locale: request.locale,
                window: window,
                cancellation: cancellation
            )

            windowResults.append((window: window, segments: segments))
        }

        // 5. Stitch windows
        let stitchedSegments = stitchWindows(
            windowResults,
            overlapStride: windowingConfig.overlapStride
        )

        // 6. Map to timeline and create proposal lines
        var proposalLines: [CaptionProposalLine] = []

        for segment in stitchedSegments {
            guard !cancellation.isCancelled else {
                throw TranscriptionError.cancelled
            }

            let (line, _) = mapToTimeline(
                segment: segment,
                window: windows[0],  // Use first window as reference; mapping uses clip directly
                clip: clip
            )

            // Skip empty or zero-duration lines
            if line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warnings.append(.emptyLineDropped)
                continue
            }
            if line.range.duration <= .zero {
                warnings.append(.zeroDurationLineDropped)
                continue
            }

            proposalLines.append(CaptionProposalLine(proposedLine: line))
        }

        // 7. Verify language
        let fullText = proposalLines.map { $0.proposedLine.text }.joined(separator: " ")
        if !fullText.isEmpty,
           let languageWarning = verifyLanguage(text: fullText, chosenLocale: request.locale) {
            warnings.append(languageWarning)
        }

        // 8. Check for no speech
        if proposalLines.isEmpty && !warnings.contains(.noSpeechDetected) {
            warnings.append(.noSpeechDetected)
        }

        return CaptionTranscriptionProposal(
            lines: proposalLines,
            warnings: warnings,
            locale: request.locale,
            sourceClipID: request.clipID
        )
    }

    // MARK: - Private Helpers

    private static func extractSegments(
        from result: SFSpeechRecognitionResult
    ) -> [RawTranscriptionSegment] {
        let transcription = result.bestTranscription
        var segments: [RawTranscriptionSegment] = []

        // SFTranscriptionSegment provides segment-level timing
        for segment in transcription.segments {
            let timestamp = CMTime(seconds: segment.timestamp, preferredTimescale: 600)
            let duration = CMTime(seconds: segment.duration, preferredTimescale: 600)

            // Extract word-level timings if available
            var words: [RawWordTiming] = []
            if segment.duration > 0 {
                // Use the segment itself as a word-level timing
                words.append(RawWordTiming(
                    timestamp: timestamp,
                    duration: duration,
                    word: segment.substring
                ))
            }

            segments.append(RawTranscriptionSegment(
                timestamp: timestamp,
                duration: duration,
                substring: segment.substring,
                words: words
            ))
        }

        return segments
    }

    private static func mergeSampleBuffers(_ buffers: [CMSampleBuffer]) throws -> AVAudioPCMBuffer {
        guard !buffers.isEmpty else {
            throw TranscriptionError.extractionFailed("No audio data")
        }

        let format = CMSampleBufferGetFormatDescription(buffers[0])!
        let audioStreamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(format)!
        let sampleRate = audioStreamDesc.pointee.mSampleRate
        let channels = audioStreamDesc.pointee.mChannelsPerFrame

        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        // Calculate total frames
        var totalFrames: AVAudioFrameCount = 0
        for buffer in buffers {
            totalFrames += AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))
        }

        guard let mergedBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: totalFrames) else {
            throw TranscriptionError.extractionFailed("Could not create merged buffer")
        }
        mergedBuffer.frameLength = totalFrames

        guard let channelData = mergedBuffer.floatChannelData?[0] else {
            throw TranscriptionError.extractionFailed("No channel data")
        }

        var frameOffset: AVAudioFrameCount = 0
        for buffer in buffers {
            let numFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))

            // Copy sample data
            if let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
                var dataPointer: UnsafeMutablePointer<Int8>?
                var dataLength: Int = 0
                CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &dataLength,
                    dataPointerOut: &dataPointer
                )

                if let dataPointer {
                    let sampleCount = Int(numFrames) * Int(channels)
                    let int16Pointer = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: sampleCount)
                    for i in 0..<sampleCount {
                        channelData[Int(frameOffset) * Int(channels) + (i % Int(channels))] =
                            Float(int16Pointer[i]) / 32768.0
                    }
                }
            }

            frameOffset += numFrames
        }

        return mergedBuffer
    }

    private static func mergeSegments(_ segments: [VADSegment], minimumSilence: Double) -> [VADSegment] {
        guard segments.count > 1 else { return segments }

        var merged: [VADSegment] = [segments[0]]
        for segment in segments.dropFirst() {
            let last = merged[merged.count - 1]
            let gap = segment.start - last.end
            if gap.seconds < minimumSilence {
                // Merge
                let newDuration = segment.end - last.start
                merged[merged.count - 1] = VADSegment(start: last.start, duration: newDuration)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func createFixedWindows(
        totalDuration: CMTime,
        clipTimelineStart: CMTime,
        sourceStart: CMTime,
        maxDuration: CMTime,
        overlap: CMTime
    ) -> [RecognitionWindow] {
        var windows: [RecognitionWindow] = []
        var offset: CMTime = .zero
        var index = 0

        while offset < totalDuration {
            let remaining = totalDuration - offset
            let windowDuration = CMTimeMinimum(remaining, maxDuration)

            windows.append(RecognitionWindow(
                index: index,
                windowOffsetInClip: offset,
                windowDuration: windowDuration,
                sourceStart: sourceStart + offset,
                clipTimelineStart: clipTimelineStart
            ))

            offset = offset + windowDuration - overlap
            if offset < .zero { offset = .zero }
            index += 1

            // Prevent infinite loop
            if windowDuration <= .zero { break }
        }

        return windows
    }

    private static func deduplicateOverlap(
        previousSegments: [RawTranscriptionSegment],
        currentSegments: [RawTranscriptionSegment],
        overlapDuration: CMTime
    ) -> [RawTranscriptionSegment] {
        guard let lastPrevious = previousSegments.last,
              !currentSegments.isEmpty else {
            return currentSegments
        }

        // Find the overlap boundary in the previous window
        let previousEndTime = lastPrevious.timestamp + lastPrevious.duration
        let overlapStart = previousEndTime - overlapDuration

        // Filter current segments that start within the overlap region
        var deduplicated: [RawTranscriptionSegment] = []

        for segment in currentSegments {
            if segment.timestamp < overlapDuration {
                // This segment is in the overlap region
                // Check if a similar word exists in the previous window
                let isDuplicate = previousSegments.contains { prev in
                    let prevEnd = prev.timestamp + prev.duration
                    return prevEnd > overlapStart
                        && Self.wordsAreSimilar(prev.substring, segment.substring)
                }
                if !isDuplicate {
                    deduplicated.append(segment)
                }
            } else {
                deduplicated.append(segment)
            }
        }

        return deduplicated
    }

    private static func wordsAreSimilar(_ a: String, _ b: String) -> Bool {
        let aWords = a.lowercased().split(separator: " ").map(String.init)
        let bWords = b.lowercased().split(separator: " ").map(String.init)
        guard !aWords.isEmpty, !bWords.isEmpty else { return false }

        // Check if any significant words match
        let significantA = aWords.filter { $0.count > 2 }
        let significantB = bWords.filter { $0.count > 2 }

        guard !significantA.isEmpty, !significantB.isEmpty else { return false }

        let setA = Set(significantA)
        let setB = Set(significantB)
        let intersection = setA.intersection(setB)

        // If more than half the words match, consider it a duplicate
        let threshold = Double(min(setA.count, setB.count)) * 0.5
        return Double(intersection.count) >= threshold
    }
}

// MARK: - Cancellation Token

/// Thread-safe cancellation token for long-running operations.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _isCancelled = false

    nonisolated var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    nonisolated func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}
