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
/// The split is deliberate: per the ROADMAP's Apple API spot-checks,
/// `AVAudioInputNode.setVoiceProcessingEnabled(_:)` (used by Phase 36 / 41 on
/// the input side) **refuses** `manualRenderingMode = .offline`, so the bus
/// cannot share one engine instance across both modes. This file lays the
/// plumbing; Phase 36 attaches its denoiser to both graphs through different
/// code paths (voice-processing on live, vDSP AU on offline) so preview and
/// export stay sample-identical.
///
/// The class is `@MainActor @Observable` because parameter edits flow from the
/// inspector and route through the existing undo machinery; sample-rate state
/// lives inside the audio nodes themselves. The peak/RMS meter snapshot is
/// updated on the audio thread under an `OSAllocatedUnfairLock` and read on
/// the main actor through the `@Observable` accessor.
///
/// **Preview wiring status.** The live engine is *not* yet wired into the
/// `AVPlayer` preview path — that's Phase 36's job, where the bus replaces
/// `AVPlayer`'s internal AU graph with an `AVAudioPlayerNode` chain. Until
/// then, `prepareLive()` exists for opt-in monitoring (e.g. mic capture in
/// Phase 41) and the inspector meter reflects whatever the live graph happens
/// to be rendering — `silent` for an unwired bus. The offline engine **is**
/// fully wired for tests and is the path Phase 36's export pipeline will use.
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

    /// Standard bus format: 48 kHz, stereo, interleaved-free Float32. Phase 36
    /// DSP normalises around this format so denoise / loudness see one
    /// canonical layout.
    static let canonicalFormat: AVAudioFormat = {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }()

    init() {}

    // MARK: - Live engine lifecycle

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
            let outputFormat = liveEngine.outputNode.outputFormat(forBus: 0)
            guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
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
    /// `setVoiceProcessingEnabled(_:)` is **never** called on this engine —
    /// the API refuses `.offline`. Phase 36's denoiser will attach a vDSP
    /// `AVAudioUnit` here instead.
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
}

// MARK: - Audio-mix parameter helpers (composition integration, R2.1 / R2.3)

/// Pure helpers that translate `Project` bus parameters into the volume
/// baselines and envelope ramps that `CompositionBuilder` writes into
/// `AVMutableAudioMixInputParameters`. Kept here, not on `Project`, so the
/// bus owns every audio-mix-shaping concern.
///
/// **Pan is not applied here.** `TrackInput.pan` is stored and persisted, but
/// applying it requires an `AVAudioMixerNode.pan` write on the live graph and
/// a panner node on the offline graph — both deferred to Phase 36 where the
/// bus actually owns the audio rendering path. Until then, the UI does not
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
