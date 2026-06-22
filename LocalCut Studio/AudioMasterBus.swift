import Foundation
import AVFoundation
import os

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
@MainActor
@Observable
final class AudioMasterBus {

    /// The latest peak + RMS sample from whichever graph is rendering. Reads
    /// land on the main actor; writes happen on the audio thread, guarded by
    /// `meterLock` so the read/write race is correctly serialised.
    var meterSnapshot: AudioMeterSnapshot {
        meterLock.withLock { $0 }
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

    @ObservationIgnored private(set) var isLiveRunning = false
    @ObservationIgnored private(set) var isOfflineRunning = false

    /// Audio-thread-published meter snapshot. `nonisolated` because the lock
    /// itself is `Sendable` and is the actual synchronisation primitive — the
    /// `@Observable` accessor reads under the same lock the tap writes under.
    @ObservationIgnored
    nonisolated private let meterLock = OSAllocatedUnfairLock<AudioMeterSnapshot>(
        initialState: .silent)

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

    /// Starts the live engine, installs the master mixer tap if needed.
    /// Idempotent: a successful re-call is a no-op; a failure tears the engine
    /// down so a later retry starts from a clean state.
    func prepareLive() {
        guard !isLiveRunning else { return }
        installLiveTapIfNeeded()
        do {
            // `prepare()` allocates render resources without starting; needed
            // for some node types before `start()`.
            liveEngine.prepare()
            try liveEngine.start()
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

    private func installLiveTapIfNeeded() {
        guard !liveTapInstalled else { return }
        let format = liveEngine.mainMixerNode.outputFormat(forBus: 0)
        // Bail rather than crash if the format is unavailable (no audio device).
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        installMeterTap(on: liveEngine.mainMixerNode, format: format)
        liveTapInstalled = true
    }

    // MARK: - Offline engine lifecycle

    /// Switches the offline engine into manual rendering mode at the supplied
    /// format and frame count, attaches a meter tap, and starts the engine so
    /// `renderOfflineBlock(into:)` can pull data through it.
    ///
    /// `setVoiceProcessingEnabled(_:)` is **never** called on this engine —
    /// the API refuses `.offline`. Phase 36's denoiser will attach a vDSP
    /// `AVAudioUnit` here instead.
    func prepareOffline(format: AVAudioFormat = AudioMasterBus.canonicalFormat,
                        maximumFrameCount: AVAudioFrameCount = 4096) throws {
        guard !isOfflineRunning else { return }

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
    }

    /// Pulls one block of audio through the offline graph into `buffer`. Meter
    /// tap fires during the pull and updates `meterSnapshot`.
    func renderOfflineBlock(into buffer: AVAudioPCMBuffer) throws -> AVAudioEngine.ManualRenderingStatus {
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
        installMeterTap(on: offlineEngine.mainMixerNode, format: format)
        offlineTapInstalled = true
    }

    // MARK: - Meter tap

    /// Installs the peak + RMS computing tap. The block runs on the audio
    /// thread; it writes through the lock and never touches `@Observable`
    /// state directly to avoid SwiftUI re-entrancy on the audio thread.
    ///
    /// `nonisolated` because the closure inherits the surrounding actor
    /// isolation by default, and the tap callback is invoked on a non-main
    /// thread — letting the closure float free of MainActor avoids a Swift 6
    /// `@Sendable` mismatch.
    nonisolated private func installMeterTap(on node: AVAudioMixerNode, format: AVAudioFormat) {
        let lock = meterLock
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let snapshot = AudioMasterBus.computeMeter(buffer: buffer)
            lock.withLock { $0 = snapshot }
        }
    }

    /// Pure-function meter compute, exposed for direct unit testing.
    nonisolated static func computeMeter(buffer: AVAudioPCMBuffer) -> AudioMeterSnapshot {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              let channelData = buffer.floatChannelData else {
            return AudioMeterSnapshot(peakLeft: 0, peakRight: 0,
                                      rmsLeft: 0, rmsRight: 0,
                                      sampledAt: ContinuousClock.now)
        }
        let channelCount = Int(buffer.format.channelCount)

        func reduce(_ ptr: UnsafePointer<Float>) -> (peak: Float, rms: Float) {
            var peak: Float = 0
            var sumSquares: Float = 0
            for i in 0..<frameCount {
                let s = ptr[i]
                let mag = abs(s)
                if mag > peak { peak = mag }
                sumSquares += s * s
            }
            let rms = (sumSquares / Float(frameCount)).squareRoot()
            return (peak, rms)
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
enum AudioBusMixing {

    /// Effective baseline volume (master × per-track gain). `1.0` for the
    /// default project, so transition crossfades stay bit-identical.
    nonisolated static func baselineVolume(masterGain: Float,
                                           trackInput: TrackInput?) -> Float {
        let g = trackInput?.gain ?? 1
        return max(0, masterGain * g)
    }
}
