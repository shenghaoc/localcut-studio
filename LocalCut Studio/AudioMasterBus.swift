import Foundation
import AVFoundation
import Accelerate
import os
import LocalCutCore

/// The native macOS port's audio master bus (P16). Owns two parallel
/// `AVAudioEngine` graphs built from one shared description:
///
/// - **liveEngine** runs in `.realTime` for preview / monitoring.
/// - **offlineEngine** runs in `.offline` (`enableManualRenderingMode`) for
///   export and tests.
///
/// Both engines share the same cleanup processing chain (T1.7/T1.8):
///     playerNode → [cleanup tap: denoise→gate→compressor→limiter] → mixer → output
///
/// The cleanup tap applies `VoiceCleanupDSP.processInterleaved` inline,
/// ensuring sample parity between preview and export.
///
/// The class is `@MainActor @Observable` because parameter edits flow from the
/// inspector and route through the existing undo machinery; sample-rate state
/// lives inside the audio nodes themselves. The peak/RMS meter snapshot is
/// updated on the audio thread under an `OSAllocatedUnfairLock` and read on
/// the main actor through the `@Observable` accessor.
@MainActor
@Observable
final class AudioMasterBus {

    /// The latest peak + RMS sample from whichever graph is rendering. Reads
    /// land on the main actor; writes happen on the audio thread, guarded by
    /// `meterLock` so the read/write race is correctly serialised.
    ///
    /// SwiftUI does not auto-track audio-thread writes through this accessor
    /// because it doesn't read observable storage; the inspector drives
    /// periodic re-reads with `TimelineView(.animation(...))` so the meter
    /// animates in lockstep with rendering instead of waiting on unrelated
    /// model state to change.
    var meterSnapshot: AudioMeterSnapshot {
        meterLock.withLock { $0 }
    }

    func setOfflineMeteringActive(_ active: Bool) {
        offlineMeterActiveLock.withLock { $0 = active }
        isOfflineMetering = active
    }

    nonisolated func publishOfflineMeterSnapshot(_ snapshot: AudioMeterSnapshot) {
        meterLock.withLock { $0 = snapshot }
    }

    nonisolated var offlineMeterSnapshotPublisher: @Sendable (AudioMeterSnapshot) -> Void {
        let meterLock = meterLock
        return { snapshot in
            meterLock.withLock { $0 = snapshot }
        }
    }

    /// Surfaces a user-visible error message (e.g. live engine start failure)
    /// without making engine startup itself throw at the call site — bus
    /// existence must not be conditional on a working audio device.
    private(set) var lastStartError: String?

    // MARK: - Internals (engines + tap state)

    @ObservationIgnored private let liveEngine = AVAudioEngine()
    @ObservationIgnored private let offlineEngine = AVAudioEngine()

    @ObservationIgnored private var liveTapInstalled = false
    @ObservationIgnored private var offlineTapInstalled = false

    private(set) var isLiveRunning = false
    private(set) var isOfflineRunning = false

    /// Mirrors `offlineMeterActiveLock` on the main actor so SwiftUI can show
    /// the meter strip while an export publishes offline snapshots — even when
    /// the live engine is stopped (the common case now that live metering is
    /// opt-in). The lock copy stays the source of truth for the audio thread.
    @MainActor
    private(set) var isOfflineMetering = false

    /// Audio-thread-published meter snapshot. `nonisolated` because the lock
    /// itself is `Sendable` and is the actual synchronisation primitive — the
    /// `@Observable` accessor reads under the same lock the tap writes under.
    @ObservationIgnored
    nonisolated private let meterLock = OSAllocatedUnfairLock<AudioMeterSnapshot>(
        initialState: .silent)

    @ObservationIgnored
    nonisolated private let offlineMeterActiveLock = OSAllocatedUnfairLock<Bool>(
        initialState: false)

    /// Player nodes attached to the offline graph and indexed by id. Phase 36 /
    /// 46 grow these for live capture; for this spec they exist so tests can
    /// schedule buffers and assert the meter publishes a non-silent snapshot.
    @ObservationIgnored private var offlinePlayers: [UUID: AVAudioPlayerNode] = [:]

    // MARK: - Live preview routing (T1.8)

    /// Player node for the live preview audio. Schedules decoded buffers from
    /// the composition and routes them through the cleanup chain.
    @ObservationIgnored private var livePlayerNode: AVAudioPlayerNode?

    /// Live cleanup settings, updated from the inspector.
    /// Use `updateLiveCleanupSettings()` to sync changes to the lock.
    var liveCleanupSettings: VoiceCleanupSettings = VoiceCleanupSettings()

    /// Updates the live cleanup settings and syncs to the lock for the render callback.
    func updateLiveCleanupSettings(_ settings: VoiceCleanupSettings) {
        var newSettings = settings
        newSettings.clamp()
        liveCleanupSettings = newSettings
        // Sync to lock using a local copy to avoid capture issues.
        let settingsCopy = newSettings
        liveCleanupSettingsLock.withLock { lock in
            lock = settingsCopy
        }
    }

    /// Per-insert gain reduction for UI metering (T2.3).
    private(set) var liveGainReduction: LiveGainReduction = LiveGainReduction()

    /// Lock-protected cleanup settings for the render callback.
    @ObservationIgnored
    nonisolated private let liveCleanupSettingsLock = OSAllocatedUnfairLock<VoiceCleanupSettings>(
        initialState: VoiceCleanupSettings())

    /// Processor state for gate/compressor gain envelopes in the live path.
    @ObservationIgnored
    nonisolated private let liveProcessorStateLock = OSAllocatedUnfairLock<VoiceCleanupProcessorState>(
        initialState: VoiceCleanupProcessorState())

    /// Gain reduction meter lock.
    @ObservationIgnored
    nonisolated private let liveGainReductionLock = OSAllocatedUnfairLock<LiveGainReduction>(
        initialState: LiveGainReduction())

    /// Bypass ramp state for glitch-free switching (T1.9).
    /// Each insert has a ramp value: 1.0 = fully bypassed, 0.0 = fully active.
    @ObservationIgnored
    nonisolated private let bypassRampLock = OSAllocatedUnfairLock<BypassRampState>(
        initialState: BypassRampState())

    /// Whether the live cleanup tap is installed.
    @ObservationIgnored private var liveCleanupTapInstalled = false

    /// Scheduling task for composition decoding.
    @ObservationIgnored nonisolated(unsafe) private var schedulingTask: Task<Void, Never>?

    /// Current composition and audio mix for seeking.
    @ObservationIgnored private var currentLiveComposition: AVComposition?
    @ObservationIgnored private var currentLiveAudioMix: AVAudioMix?

    /// Standard bus format: 48 kHz, stereo, interleaved-free Float32. Phase 36
    /// DSP normalises around this format so denoise / loudness see one
    /// canonical layout.
    static let canonicalFormat: AVAudioFormat = {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }()

    init() {}

    // MARK: - Live engine lifecycle

    /// Starts the live engine for preview with the cleanup processing chain.
    /// Installs a player node → cleanup tap → mixer → output graph.
    func prepareLiveForPreview() throws {
        guard !isLiveRunning else { return }

        do {
            let format = AudioMasterBus.canonicalFormat

            // Create and attach the live player node.
            let player = AVAudioPlayerNode()
            liveEngine.attach(player)
            livePlayerNode = player

            // Install cleanup tap on the player node (processes in-place).
            installLiveCleanupTap(on: player, format: format)

            // Connect player → main mixer.
            liveEngine.connect(player, to: liveEngine.mainMixerNode, format: format)

            // Install meter tap on the main mixer.
            let deviceFormat = liveEngine.outputNode.inputFormat(forBus: 0)
            guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else {
                throw LiveMeterError.unavailableOutputFormat
            }
            try liveEngine.start()
            installMeterTap(on: liveEngine.mainMixerNode, format: deviceFormat,
                            suspendsForOfflineMeter: true)
            player.play()
            isLiveRunning = true
            lastStartError = nil
        } catch {
            lastStartError = error.localizedDescription
            teardownLive()
            throw error
        }
    }

    /// Starts the live engine, installs the master mixer tap **after** the
    /// engine is running so the tap reads the actual hardware-matched output
    /// format (installing before `start()` can crash on a format mismatch when
    /// the device negotiates a different layout). Idempotent: a successful
    /// re-call is a no-op; a failure tears the engine down so a later retry
    /// starts from a clean state.
    func prepareLive() {
        guard !isLiveRunning else { return }
        do {
            // Pre-flight the output device. `AVAudioEngine.start()` lazily
            // connects mainMixerNode → outputNode and calls
            // `-[AVAudioEngine prepare]`, whose graph `Initialize` *raises an
            // Objective-C exception* ("required condition is false:
            // IsFormatSampleRateAndChannelCountValid") when the output device
            // has no valid format — e.g. on a headless box, or during AppKit
            // window state-restoration at launch before the audio HAL is ready.
            // A Swift `do/catch` cannot intercept a raised ObjC exception, so
            // that case crashes the whole app. Validating the format first lets
            // us throw a Swift error (handled below) before reaching `prepare()`.
            let deviceFormat = liveEngine.outputNode.inputFormat(forBus: 0)
            guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else {
                throw LiveMeterError.unavailableOutputFormat
            }
            try liveEngine.start()
            try installLiveTapIfNeeded()
            isLiveRunning = true
            lastStartError = nil
        } catch {
            // Headless test runners / no-audio-device environments can land
            // here. Surface the error and tear back down so the bus stays in
            // a clean state for later retries.
            lastStartError = error.localizedDescription
            os_log(.error, "AudioMasterBus: liveEngine.start failed: %{public}@",
                   error.localizedDescription)
            teardownLive()
        }
    }

    /// Stops the live engine and removes the mixer tap. Idempotent.
    func teardownLive() {
        schedulingTask?.cancel()
        schedulingTask = nil

        if let player = livePlayerNode {
            player.stop()
            liveEngine.detach(player)
            livePlayerNode = nil
        }
        if liveCleanupTapInstalled {
            liveEngine.mainMixerNode.removeTap(onBus: 0)
            liveCleanupTapInstalled = false
        }
        if liveTapInstalled {
            liveEngine.mainMixerNode.removeTap(onBus: 0)
            liveTapInstalled = false
        }
        if liveEngine.isRunning {
            liveEngine.stop()
        }
        liveEngine.reset()
        isLiveRunning = false
    }

    private func installLiveTapIfNeeded() throws {
        guard !liveTapInstalled else { return }
        let format = liveEngine.mainMixerNode.outputFormat(forBus: 0)
        // Throw rather than crash if the format is unavailable (no audio
        // device). Propagating lets `prepareLive()` record the error and tear
        // the engine down instead of leaving a running-but-untapped graph that
        // reports `isLiveRunning == true` while metering nothing.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw LiveMeterError.unavailableOutputFormat
        }
        installMeterTap(on: liveEngine.mainMixerNode, format: format,
                        suspendsForOfflineMeter: true)
        liveTapInstalled = true
    }

    // MARK: - Live cleanup tap (T1.7, T1.9)

    /// Installs a tap that processes audio through the cleanup chain.
    /// The tap runs on the audio thread and applies `VoiceCleanupDSP.processInterleaved`
    /// inline, ensuring sample parity with offline export.
    ///
    /// **Bypass ramping (T1.9).** Each insert has a ramp value [0,1] where
    /// 1.0 = fully bypassed and 0.0 = fully active. The ramp transitions over
    /// ~5 ms (240 frames at 48 kHz) to avoid clicks when toggling bypass.
    private func installLiveCleanupTap(on node: AVAudioPlayerNode, format: AVAudioFormat) {
        guard !liveCleanupTapInstalled else { return }
        let settingsRef = liveCleanupSettingsLock
        let stateRef = liveProcessorStateLock
        let gainRef = liveGainReductionLock
        let rampRef = bypassRampLock
        let sampleRate = format.sampleRate
        // Ramp duration: ~5 ms at 48 kHz = 240 samples.
        let rampSamples = Int(0.005 * sampleRate)

        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0, let floatData = buffer.floatChannelData else {
                return
            }

            // Read current settings.
            let currentSettings = settingsRef.withLock { $0 }

            let bypassRamp = rampRef.withLock { ramp in
                let targetDenoiser: Float = currentSettings.denoiser.bypass ? 1.0 : 0.0
                let targetGate: Float = currentSettings.gate.bypass ? 1.0 : 0.0
                let targetCompressor: Float = currentSettings.compressor.bypass ? 1.0 : 0.0
                let targetLimiter: Float = currentSettings.limiter.bypass ? 1.0 : 0.0

                let snapshot = VoiceCleanupInsertBypassRamp(
                    denoiserStartBypass: ramp.denoiserBypass,
                    denoiserTargetBypass: targetDenoiser,
                    gateStartBypass: ramp.gateBypass,
                    gateTargetBypass: targetGate,
                    compressorStartBypass: ramp.compressorBypass,
                    compressorTargetBypass: targetCompressor,
                    limiterStartBypass: ramp.limiterBypass,
                    limiterTargetBypass: targetLimiter,
                    rampFrames: rampSamples)
                ramp.advance(targetDenoiserBypass: targetDenoiser,
                             targetGateBypass: targetGate,
                             targetCompressorBypass: targetCompressor,
                             targetLimiterBypass: targetLimiter,
                             frameCount: frameCount,
                             rampFrames: rampSamples)
                return snapshot
            }

            // Convert non-interleaved to interleaved for VoiceCleanupDSP.
            var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    interleaved[frame * channelCount + channel] = floatData[channel][frame]
                }
            }

            // Process audio inline using the lock for processor state.
            let inputForProcessing = interleaved
            interleaved = stateRef.withLock { state in
                var processed = inputForProcessing
                VoiceCleanupDSP.processInterleaved(
                    &processed,
                    channels: channelCount,
                    sampleRate: sampleRate,
                    settings: currentSettings,
                    state: &state,
                    bypassRamp: bypassRamp)
                return processed
            }

            // Write back to the buffer (non-interleaved).
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    floatData[channel][frame] = interleaved[frame * channelCount + channel]
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
        }
        liveCleanupTapInstalled = true
    }

    // MARK: - Live composition scheduling (T1.8)

    /// Schedules audio from the composition for live preview playback.
    /// Decodes the composition and schedules buffers on the live player node.
    func scheduleLiveComposition(_ composition: AVComposition,
                                  audioMix: AVAudioMix?,
                                  startTime: CMTime = .zero) {
        schedulingTask?.cancel()
        schedulingTask = nil

        guard isLiveRunning, let player = livePlayerNode else { return }

        // Store composition for seeking.
        currentLiveComposition = composition
        currentLiveAudioMix = audioMix

        // Sync cleanup settings from the project (lock-protected).
        // The didSet on liveCleanupSettings already syncs to the lock,
        // but we also sync here in case settings changed without triggering didSet.
        let currentSettings = liveCleanupSettings
        liveCleanupSettingsLock.withLock { $0 = currentSettings }

        // Reset processor state for the new schedule.
        liveProcessorStateLock.withLock { $0 = VoiceCleanupProcessorState() }
        player.stop()

        nonisolated(unsafe) let comp = composition
        nonisolated(unsafe) let mix = audioMix
        schedulingTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.decodeAndScheduleLive(composition: comp,
                                              audioMix: mix,
                                              startTime: startTime)
        }
    }

    /// Seeks to a new position in the current composition.
    func seekLivePreview(to time: CMTime, composition: AVComposition, audioMix: AVAudioMix?) {
        schedulingTask?.cancel()
        livePlayerNode?.stop()
        livePlayerNode?.reset()
        liveProcessorStateLock.withLock { $0 = VoiceCleanupProcessorState() }

        nonisolated(unsafe) let comp = composition
        nonisolated(unsafe) let mix = audioMix
        schedulingTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.decodeAndScheduleLive(composition: comp,
                                              audioMix: mix,
                                              startTime: time)
        }
    }

    /// Seeks to a new position using the current composition.
    func seekLivePreview(to time: CMTime) {
        guard let composition = currentLiveComposition else { return }
        seekLivePreview(to: time, composition: composition, audioMix: currentLiveAudioMix)
    }

    /// Pauses the live preview playback.
    func pauseLivePreview() {
        livePlayerNode?.pause()
    }

    /// Resumes the live preview playback.
    func resumeLivePreview() {
        livePlayerNode?.play()
    }

    /// Decodes the composition and schedules buffers on the live player.
    private func decodeAndScheduleLive(composition: AVComposition,
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
                    AVLinearPCMIsNonInterleaved: false,
                ])
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else { return }
            reader.add(output)

            if startTime > .zero {
                let duration = composition.duration
                reader.timeRange = CMTimeRange(start: startTime, end: duration)
            }

            guard reader.startReading() else { return }

            let format = AudioMasterBus.canonicalFormat
            let frameCapacity: AVAudioFrameCount = 1024

            while reader.status == .reading {
                guard !Task.isCancelled else { break }

                if let sampleBuffer = output.copyNextSampleBuffer() {
                    guard let pcmBuffer = convertToPCMBuffer(
                        sampleBuffer: sampleBuffer,
                        format: format,
                        frameCapacity: frameCapacity) else { continue }

                    if !Task.isCancelled {
                        await MainActor.run { [weak self] in
                            self?.livePlayerNode?.scheduleBuffer(pcmBuffer, completionHandler: nil)
                        }
                    }
                } else {
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

        // Source is interleaved Float32 (matching the reader settings).
        let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(
            to: Float.self, capacity: frameCount * channelCount)

        for channel in 0..<channelCount {
            for frame in 0..<samplesPerChannel {
                floatData[channel][frame] = floatPointer[frame * channelCount + channel]
            }
        }

        return buffer
    }

    /// Failures raised while bringing the live metering graph up.
    private enum LiveMeterError: LocalizedError {
        /// The live engine started but its main mixer reported no usable output
        /// format (no audio device / headless environment), so no tap could be
        /// installed.
        case unavailableOutputFormat

        var errorDescription: String? {
            switch self {
            case .unavailableOutputFormat:
                return "No audio output format is available for live metering."
            }
        }
    }

    // MARK: - Offline engine lifecycle

    /// Switches the offline engine into manual rendering mode at the supplied
    /// format and frame count, attaches a meter tap, and starts the engine so
    /// `renderOfflineBlock(into:)` can pull data through it.
    ///
    /// `setVoiceProcessingEnabled(_:)` is **never** called on this engine:
    /// Phase 36's cleanup is a master-bus/export concern for existing media,
    /// not the input-node microphone processing used by capture phases.
    ///
    /// Setup is wrapped so a failure (manual-rendering enable, start) tears
    /// down the partially-attached graph before rethrowing — a later retry
    /// then starts from a clean state instead of stacking another player /
    /// tap onto the dirty engine.
    func prepareOffline(format: AVAudioFormat = AudioMasterBus.canonicalFormat,
                        maximumFrameCount: AVAudioFrameCount = 4096) throws {
        guard !isOfflineRunning else { return }

        do {
            // Attach a player node lazily so tests can write samples into the
            // offline graph without a source file.
            let playerID = UUID()
            let player = AVAudioPlayerNode()
            offlineEngine.attach(player)
            offlineEngine.connect(player, to: offlineEngine.mainMixerNode, format: format)
            offlinePlayers[playerID] = player

            try offlineEngine.enableManualRenderingMode(.offline,
                                                        format: format,
                                                        maximumFrameCount: maximumFrameCount)
            installOfflineTapIfNeeded(format: format)
            offlineEngine.prepare()
            try offlineEngine.start()
            // Start every attached player so scheduled buffers actually play out.
            for player in offlinePlayers.values { player.play() }
            isOfflineRunning = true
        } catch {
            // Partial-setup teardown leaves the engine ready for a retry.
            teardownOffline()
            throw error
        }
    }

    /// Pulls one block of audio through the offline graph into `buffer`. Meter
    /// tap fires during the pull and updates `meterSnapshot`.
    func renderOfflineBlock(into buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        try offlineEngine.renderOffline(buffer.frameCapacity, to: buffer)
    }

    /// Schedules a single buffer for offline playback on the next render call.
    /// Returns the id of the player node it was scheduled on so tests can
    /// re-target the same player.
    @discardableResult
    func scheduleOfflineBuffer(_ buffer: AVAudioPCMBuffer) -> UUID? {
        guard let (id, player) = offlinePlayers.first else { return nil }
        player.scheduleBuffer(buffer, completionHandler: nil)
        return id
    }

    /// Stops and tears down the offline graph. Idempotent.
    func teardownOffline() {
        if offlineTapInstalled {
            offlineEngine.mainMixerNode.removeTap(onBus: 0)
            offlineTapInstalled = false
        }
        if offlineEngine.isRunning {
            offlineEngine.stop()
        }
        for (_, player) in offlinePlayers {
            player.stop()
            offlineEngine.detach(player)
        }
        offlinePlayers.removeAll()
        offlineEngine.disableManualRenderingMode()
        offlineEngine.reset()
        isOfflineRunning = false
    }

    private func installOfflineTapIfNeeded(format: AVAudioFormat) {
        guard !offlineTapInstalled else { return }
        installMeterTap(on: offlineEngine.mainMixerNode, format: format,
                        suspendsForOfflineMeter: false)
        offlineTapInstalled = true
    }

    // MARK: - Meter tap

    /// Installs the peak + RMS computing tap. The block runs on the audio
    /// thread; it writes through the lock and never touches `@Observable`
    /// state directly to avoid SwiftUI re-entrancy on the audio thread.
    ///
    /// Captures only the `Sendable` lock in the closure's capture list so the
    /// tap callback is safely `@Sendable` and non-isolated, running on the
    /// audio thread without any MainActor mismatch.
    private func installMeterTap(on node: AVAudioMixerNode,
                                 format: AVAudioFormat,
                                 suspendsForOfflineMeter: Bool) {
        let lock = meterLock
        let offlineActive = offlineMeterActiveLock
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [lock, offlineActive] buffer, _ in
            if suspendsForOfflineMeter && offlineActive.withLock({ $0 }) {
                return
            }
            let snapshot = AudioMasterBus.computeMeter(buffer: buffer)
            lock.withLock { $0 = snapshot }
        }
    }

    /// Pure-function meter compute, exposed for direct unit testing.
    /// Uses Accelerate's `vDSP_maxmgv` + `vDSP_measqv` for the per-channel
    /// reduction so the tap fits inside the audio thread's budget at 48 kHz
    /// stereo (manual scalar loops at 1024-frame blocks would burn an order
    /// of magnitude more cycles).
    nonisolated static func computeMeter(buffer: AVAudioPCMBuffer) -> AudioMeterSnapshot {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              let channelData = buffer.floatChannelData else {
            return AudioMeterSnapshot(peakLeft: 0, peakRight: 0,
                                       rmsLeft: 0, rmsRight: 0,
                                       sampledAt: ContinuousClock.now)
        }
        let channelCount = Int(buffer.format.channelCount)
        let length = vDSP_Length(frameCount)

        func reduce(_ ptr: UnsafePointer<Float>) -> (peak: Float, rms: Float) {
            var peak: Float = 0
            var meanSquare: Float = 0
            vDSP_maxmgv(ptr, 1, &peak, length)
            vDSP_measqv(ptr, 1, &meanSquare, length)
            return (peak, meanSquare.squareRoot())
        }

        let l = reduce(channelData[0])
        let r = channelCount > 1 ? reduce(channelData[1]) : l
        return AudioMeterSnapshot(peakLeft: l.peak, peakRight: r.peak,
                                   rmsLeft: l.rms, rmsRight: r.rms,
                                   sampledAt: ContinuousClock.now)
    }

    /// Reads the latest gain reduction from the live cleanup tap. Updated on
    /// the audio thread; read on the main actor for the inspector meters.
    func readLiveGainReduction() -> LiveGainReduction {
        liveGainReductionLock.withLock { $0 }
    }
}

// MARK: - Live gain reduction metering (T2.3)

/// Per-insert gain reduction values from the live cleanup chain.
struct LiveGainReduction: Sendable {
    var denoiserReduction: Float = 0
    var gateReduction: Float = 0
    var compressorReduction: Float = 0
    var limiterReduction: Float = 0
}

/// Bypass ramp state for glitch-free switching (T1.9).
/// Each insert has a ramp value [0,1] where 1.0 = fully bypassed, 0.0 = fully active.
/// The ramp transitions over ~5 ms to avoid clicks when toggling bypass.
struct BypassRampState: Sendable {
    var denoiserBypass: Float = 1.0
    var gateBypass: Float = 1.0
    var compressorBypass: Float = 1.0
    var limiterBypass: Float = 1.0

    nonisolated mutating func advance(targetDenoiserBypass: Float,
                                      targetGateBypass: Float,
                                      targetCompressorBypass: Float,
                                      targetLimiterBypass: Float,
                                      frameCount: Int,
                                      rampFrames: Int) {
        denoiserBypass = Self.rampedValue(start: denoiserBypass,
                                          target: targetDenoiserBypass,
                                          frameOffset: frameCount,
                                          rampFrames: rampFrames)
        gateBypass = Self.rampedValue(start: gateBypass,
                                      target: targetGateBypass,
                                      frameOffset: frameCount,
                                      rampFrames: rampFrames)
        compressorBypass = Self.rampedValue(start: compressorBypass,
                                            target: targetCompressorBypass,
                                            frameOffset: frameCount,
                                            rampFrames: rampFrames)
        limiterBypass = Self.rampedValue(start: limiterBypass,
                                         target: targetLimiterBypass,
                                         frameOffset: frameCount,
                                         rampFrames: rampFrames)
    }

    nonisolated private static func rampedValue(start: Float,
                                                target: Float,
                                                frameOffset: Int,
                                                rampFrames: Int) -> Float {
        VoiceCleanupDSP.rampedBypass(start: start,
                                     target: target,
                                     frameOffset: frameOffset,
                                     rampFrames: rampFrames)
    }
}

// MARK: - Audio-mix parameter helpers (composition integration, R2.1 / R2.3)

/// Pure helpers that translate `Project` bus parameters into the volume
/// baselines and envelope ramps that `CompositionBuilder` writes into
/// `AVMutableAudioMixInputParameters`. Kept here, not on `Project`, so the
/// bus owns every audio-mix-shaping concern.
///
/// **Pan is not applied here.** `TrackInput.pan` is stored and persisted, but
/// applying it requires an `AVAudioMixerNode.pan` write on the live graph and
/// a panner node on the offline graph — both deferred until the bus actually
/// owns the live audio rendering path. Until then, the UI does not
/// expose a pan control, so a project's pan field stays at its default.
enum AudioBusMixing {

    /// Effective baseline volume (master × per-track gain). `1.0` for the
    /// default project, so transition crossfades stay bit-identical.
    nonisolated static func baselineVolume(masterGain: Float,
                                           trackInput: TrackInput?) -> Float {
        let g = trackInput?.gain ?? 1
        return max(0, masterGain * g)
    }
}
