import Foundation
import AVFoundation
import Accelerate
import LocalCutCore

/// Manages the live preview audio routing through the voice-cleanup processing
/// chain. Owns an `AVAudioEngine` with the node graph:
///
///     AVAudioPlayerNode → [cleanup tap] → mainMixerNode → outputNode
///
/// The cleanup tap applies denoise → gate → compressor → limiter using the
/// same `VoiceCleanupDSP` code path as offline export, ensuring sample parity
/// between preview and export.
///
/// **Threading.** The engine runs on a real-time audio thread. Settings updates
/// from the main actor are captured atomically; the render callback reads them
/// under an `OSAllocatedUnfairLock`.
@MainActor
final class LivePreviewAudioRouter {

    /// The engine driving the live preview audio.
    private let engine = AVAudioEngine()

    /// Player node that schedules decoded audio buffers.
    private let playerNode = AVAudioPlayerNode()

    /// Cleanup settings, updated from the inspector.
    /// Use `updateSettings()` to sync changes to the lock.
    var settings: VoiceCleanupSettings = VoiceCleanupSettings()

    /// Updates the cleanup settings and syncs to the lock for the render callback.
    func updateSettings(_ newSettings: VoiceCleanupSettings) {
        var clamped = newSettings
        clamped.clamp()
        settings = clamped
        let settingsCopy = clamped
        settingsLock.withLock { lock in
            lock = settingsCopy
        }
    }

    /// Whether the engine is running and ready to play.
    private(set) var isRunning = false

    /// Last error from engine startup.
    private(set) var lastError: String?

    // MARK: - Processing state

    /// Lock-protected settings for the render callback.
    @ObservationIgnored
    nonisolated private let settingsLock = OSAllocatedUnfairLock<VoiceCleanupSettings>(
        initialState: VoiceCleanupSettings())

    /// Processor state (gate/compressor gain envelopes).
    @ObservationIgnored
    nonisolated private let stateLock = OSAllocatedUnfairLock<VoiceCleanupProcessorState>(
        initialState: VoiceCleanupProcessorState())

    /// Gain reduction lock for UI metering.
    @ObservationIgnored
    nonisolated private let gainReductionLock = OSAllocatedUnfairLock<InsertGainReduction>(
        initialState: InsertGainReduction())

    /// Meter snapshot for the live preview path.
    @ObservationIgnored
    nonisolated private let meterSnapshotLock = OSAllocatedUnfairLock<AudioMeterSnapshot>(
        initialState: .silent)

    /// The latest meter snapshot from the live preview chain.
    var meterSnapshot: AudioMeterSnapshot {
        meterSnapshotLock.withLock { $0 }
    }

    /// Reads the latest gain reduction from the cleanup tap.
    var gainReduction: InsertGainReduction {
        gainReductionLock.withLock { $0 }
    }

    // MARK: - Composition reader

    /// Reads decoded audio from the composition and schedules it on the player.
    @ObservationIgnored nonisolated(unsafe) private var schedulingTask: Task<Void, Never>?
    @ObservationIgnored private var currentComposition: AVComposition?
    @ObservationIgnored nonisolated(unsafe) private var currentAudioMix: AVAudioMix?

    /// Format for the cleanup chain (48 kHz stereo Float32).
    static let processingFormat = AudioMasterBus.canonicalFormat

    init() {}

    // MARK: - Engine lifecycle

    /// Starts the live engine and installs the cleanup processing chain.
    func prepare() throws {
        guard !isRunning else { return }

        do {
            let format = Self.processingFormat

            // Attach and connect nodes.
            engine.attach(playerNode)

            // Install cleanup tap on the main mixer (processes in-place).
            installCleanupTap(on: engine.mainMixerNode, format: format)

            // Connect player → main mixer.
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)

            // Validate the output device format before starting.
            let outputFormat = engine.outputNode.inputFormat(forBus: 0)
            guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
                throw LivePreviewError.noOutputDevice
            }

            engine.prepare()
            try engine.start()
            playerNode.play()
            isRunning = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            teardown()
            throw error
        }
    }

    /// Stops the engine and releases all resources. Idempotent.
    func teardown() {
        schedulingTask?.cancel()
        schedulingTask = nil

        playerNode.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        engine.detach(playerNode)
        engine.reset()
        isRunning = false
    }

    // MARK: - Composition scheduling

    /// Schedules audio from the composition for live preview playback.
    /// Resets any previous schedule and starts decoding from `startTime`.
    func scheduleComposition(_ composition: AVComposition,
                             audioMix: AVAudioMix?,
                             startTime: CMTime = .zero) {
        // Cancel any in-flight scheduling.
        schedulingTask?.cancel()
        schedulingTask = nil

        currentComposition = composition
        currentAudioMix = audioMix

        // Reset the processor state for the new schedule.
        stateLock.withLock { $0 = VoiceCleanupProcessorState() }

        // Stop the player before rescheduling.
        playerNode.stop()

        // Schedule decoded audio on a background task.
        nonisolated(unsafe) let comp = composition
        nonisolated(unsafe) let mix = audioMix
        schedulingTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.decodeAndSchedule(composition: comp,
                                          audioMix: mix,
                                          startTime: startTime)
        }
    }

    /// Seeks to a new position in the current composition.
    func seek(to time: CMTime) {
        guard let composition = currentComposition else { return }
        schedulingTask?.cancel()
        playerNode.stop()
        playerNode.reset()
        stateLock.withLock { $0 = VoiceCleanupProcessorState() }

        nonisolated(unsafe) let comp = composition
        nonisolated(unsafe) let mix = currentAudioMix
        schedulingTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.decodeAndSchedule(composition: comp,
                                          audioMix: mix,
                                          startTime: time)
        }
    }

    /// Pauses the live preview playback.
    func pause() {
        playerNode.pause()
    }

    /// Resumes the live preview playback.
    func resume() {
        playerNode.play()
    }

    // MARK: - Private

    /// Decodes the composition and schedules buffers on the player node.
    private func decodeAndSchedule(composition: AVComposition,
                                   audioMix: AVAudioMix?,
                                   startTime: CMTime) async {
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return }

        do {
            let reader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: true,
                ])
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else { return }
            reader.add(output)

            // Seek to the requested start time.
            if startTime > .zero {
                let duration = composition.duration
                let seekRange = CMTimeRange(start: startTime, end: duration)
                reader.timeRange = seekRange
            }

            guard reader.startReading() else { return }

            let format = Self.processingFormat
            let framesPerBuffer: AVAudioFrameCount = 1024

            while reader.status == .reading {
                guard !Task.isCancelled else { break }

                if let sampleBuffer = output.copyNextSampleBuffer() {
                    // Convert CMSampleBuffer to AVAudioPCMBuffer.
                    guard let pcmBuffer = convertToPCMBuffer(
                        sampleBuffer: sampleBuffer,
                        format: format,
                        frameCapacity: framesPerBuffer) else { continue }

                    if !Task.isCancelled {
                        await MainActor.run { [weak self] in
                            self?.playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
                        }
                    }
                } else {
                    // No more data; wait briefly then check again.
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        } catch {
            // Reader failed; silently stop scheduling.
        }
    }

    /// Converts a CMSampleBuffer to an AVAudioPCMBuffer in the processing format.
    nonisolated private func convertToPCMBuffer(sampleBuffer: CMSampleBuffer,
                                     format: AVAudioFormat,
                                     frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: min(frameCapacity, AVAudioFrameCount(frameCount))) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let floatData = buffer.floatChannelData else { return nil }

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &dataLength,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer else { return nil }

        let channelCount = Int(format.channelCount)
        let samplesPerChannel = frameCount

        // Source is non-interleaved Float32 (matching the reader settings).
        let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(
            to: Float.self, capacity: frameCount * channelCount)

        for channel in 0..<channelCount {
            for frame in 0..<samplesPerChannel {
                floatData[channel][frame] = floatPointer[frame * channelCount + channel]
            }
        }

        return buffer
    }

    /// Installs a tap that processes audio through the cleanup chain.
    nonisolated private func installCleanupTap(on node: AVAudioMixerNode, format: AVAudioFormat) {
        let settingsRef = settingsLock
        let stateRef = stateLock
        let gainRef = gainReductionLock
        let meterRef = meterSnapshotLock

        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0, let floatData = buffer.floatChannelData else {
                return
            }

            // Read current settings.
            let currentSettings = settingsRef.withLock { $0 }

            // Process audio inline using the lock for processor state.
            stateRef.withLock { state in
                // Convert non-interleaved to interleaved for VoiceCleanupDSP.
                var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        interleaved[frame * channelCount + channel] = floatData[channel][frame]
                    }
                }

                // Apply cleanup DSP.
                VoiceCleanupDSP.processInterleaved(
                    &interleaved,
                    channels: channelCount,
                    sampleRate: buffer.format.sampleRate,
                    settings: currentSettings,
                    state: &state)

                // Write back to the buffer (non-interleaved).
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        floatData[channel][frame] = interleaved[frame * channelCount + channel]
                    }
                }
            }

            // Compute gain reduction for metering (T2.3).
            let finalState = stateRef.withLock { $0 }
            gainRef.withLock { reduction in
                reduction.denoiserReduction = currentSettings.denoiser.bypass ? 0 :
                    (1 - VoiceCleanupDSP.linearGain(fromDB: currentSettings.denoiser.noiseFloorDB))
                reduction.compressorReduction = finalState.compressorGain < 1 ?
                    VoiceCleanupDSP.decibels(fromLinear: finalState.compressorGain) : 0
                reduction.gateReduction = finalState.gateGain < 1 ?
                    VoiceCleanupDSP.decibels(fromLinear: finalState.gateGain) : 0
            }

            // Update meter snapshot.
            let snapshot = AudioMasterBus.computeMeter(buffer: buffer)
            meterRef.withLock { $0 = snapshot }
        }
    }
}

/// Per-insert gain reduction values for UI metering (T2.3).
struct InsertGainReduction: Sendable {
    var denoiserReduction: Float = 0
    var gateReduction: Float = 0
    var compressorReduction: Float = 0
    var limiterReduction: Float = 0
}

/// Errors from the live preview audio router.
enum LivePreviewError: LocalizedError {
    case noOutputDevice

    var errorDescription: String? {
        switch self {
        case .noOutputDevice:
            return "No audio output device is available for live preview."
        }
    }
}
