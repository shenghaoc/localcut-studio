import SwiftUI
import Foundation
import AVFoundation
import LocalCutCore

/// Maps the audio gain sliders between linear amplitude (what the model stores)
/// and decibels (what the slider travels in), so equal travel is equal dB — the
/// log mapping feature-audio-master-bus's design specified. A linear 0…2 slider
/// cramped all useful control around unity and spent its lower half on
/// inaudible levels; a −60…+6 dB fader gives fine control where mixing happens.
nonisolated enum AudioGainMapping {
    static let minDecibels: Double = -60
    static let maxDecibels: Double = 6
    static let sliderStepDecibels: Double = 0.5

    /// Linear amplitude → clamped slider decibels. Zero / sub-threshold gain
    /// pins to the −60 dB floor instead of −∞.
    static func decibels(fromLinear linear: Double) -> Double {
        guard linear > 0 else { return minDecibels }
        return min(maxDecibels, max(minDecibels, 20 * log10(linear)))
    }

    /// Slider decibels → linear amplitude. The −60 dB floor maps to silence.
    static func linear(fromDecibels decibels: Double) -> Double {
        guard decibels > minDecibels else { return 0 }
        return pow(10, decibels / 20)
    }
}

/// Inspector section for the audio master bus (P16). Renders the master gain
/// slider + a two-channel peak/RMS meter, plus per-audio-track gain rows.
/// Phase 36's insert toggles (denoiser, gate, compressor, limiter) will land
/// beneath the meter; the section keeps that space.
///
/// Per-clip fade controls live inside the clip section of `InspectorView`
/// (added below) when the selected clip sits on an audio track — they are
/// part of the clip's identity, not the bus.
struct AudioInspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section("Audio") {
            // Shared row (matches the per-track gain rows below): drag-end commits
            // the coalesced gesture as one undo step; right-click resets to unity.
            LabeledSliderRow(
                label: "Master Gain",
                spokenLabel: "Master gain",
                display: formattedGain(model.project.masterGain),
                value: masterGainBinding,
                range: AudioGainMapping.minDecibels...AudioGainMapping.maxDecibels,
                step: AudioGainMapping.sliderStepDecibels,
                captionStyle: .leadingTrailing,
                onEditingChanged: { editing in
                    if !editing { model.commitCoalescedUndo() }
                },
                resetAction: {
                    model.setMasterGain(1, coalesced: true)
                    model.commitCoalescedUndo()
                })

            // SwiftUI.TimelineView (fully qualified — the repo also defines
            // a `TimelineView` struct for the editor's timeline lane, which
            // would otherwise win name resolution and route this call to its
            // `init(model:)` instead). Driving repaints on a fixed cadence
            // lets audio-thread tap writes flow through to the meter without
            // forcing the bus to mirror its snapshot onto an `@Observable`
            // property on every audio block.
            //
            if model.audioBus.isLiveRunning || model.audioBus.isOfflineMetering {
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    MeterStrip(snapshot: model.audioBus.meterSnapshot)
                        .frame(height: 18)
                        .accessibilityLabel("Master output meter")
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(audioMeterStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(audioMeterStatus)
                    Button("Start Live Meter") {
                        model.prepareAudioMetering()
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Start live audio meter")
                }
            }

            voiceCleanupControls

            ForEach(model.project.audioTracks) { track in
                trackGainRow(track)
            }
        }
    }

    @ViewBuilder
    private var voiceCleanupControls: some View {
        DisclosureGroup("Voice Cleanup") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Insert Order")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(VoiceCleanupSettings.insertOrder, id: \.self) { insert in
                        Text(insert.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .accessibilityLabel("Insert order: denoiser, gate, compressor, limiter")
            }

            Toggle("Denoiser", isOn: insertEnabledBinding(\.denoiser.bypass, target: "audio.voiceCleanup.denoiser.bypass"))
                .accessibilityLabel("Denoiser enabled")
            if !model.project.voiceCleanup.denoiser.bypass {
                LabeledSliderRow(
                    label: "Reduction",
                    display: "\(Int(model.project.voiceCleanup.denoiser.reduction * 100))%",
                    value: voiceCleanupBinding(\.denoiser.reduction, target: "audio.voiceCleanup.denoiser.reduction"),
                    range: 0...1,
                    step: 0.05,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
                LabeledSliderRow(
                    label: "Noise Floor",
                    display: String(format: "%.0f dB", model.project.voiceCleanup.denoiser.noiseFloorDB),
                    value: voiceCleanupBinding(\.denoiser.noiseFloorDB, target: "audio.voiceCleanup.denoiser.floor"),
                    range: -90 ... -20,
                    step: 1,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
            }

            Divider()

            Picker("Loudness", selection: loudnessPresetBinding) {
                ForEach(LoudnessPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            if model.project.voiceCleanup.loudness.preset == .custom {
                LabeledSliderRow(
                    label: "Target",
                    display: String(format: "%.0f LUFS", model.project.voiceCleanup.loudness.customTargetLUFS),
                    value: customTargetBinding,
                    range: -36 ... -6,
                    step: 1,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
            }
            LabeledSliderRow(
                label: "Applied Gain",
                display: String(format: "%+.1f dB", model.project.voiceCleanup.loudness.appliedGainDB),
                value: appliedGainBinding,
                range: -30 ... 30,
                step: 0.5,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                resetAction: {
                    model.updateVoiceCleanup("Reset Loudness Normalisation") {
                        $0.loudness.enabled = false
                        $0.loudness.appliedGainDB = 0
                        $0.loudness.measuredLUFS = nil
                        $0.loudness.statusNote = nil
                    }
                })
            HStack {
                Button("Measure Now") {
                    model.measureCurrentProjectLoudness()
                }
                .disabled(model.project.duration.seconds < 3)
                Spacer()
                if let measured = model.project.voiceCleanup.loudness.measuredLUFS {
                    Text(String(format: "%.1f LUFS", measured))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let note = model.project.voiceCleanup.loudness.statusNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Gate", isOn: insertEnabledBinding(\.gate.bypass, target: "audio.voiceCleanup.gate.bypass"))
                .accessibilityLabel("Gate enabled")
            if !model.project.voiceCleanup.gate.bypass {
                LabeledSliderRow(label: "Threshold",
                                 display: String(format: "%.0f dB", model.project.voiceCleanup.gate.thresholdDB),
                                 value: voiceCleanupBinding(\.gate.thresholdDB, target: "audio.voiceCleanup.gate.threshold"),
                                 range: -80 ... 0, step: 1,
                                 onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
                LabeledSliderRow(label: "Range",
                                 display: String(format: "%.0f dB", model.project.voiceCleanup.gate.rangeDB),
                                 value: voiceCleanupBinding(\.gate.rangeDB, target: "audio.voiceCleanup.gate.range"),
                                 range: -80 ... 0, step: 1,
                                 onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
                LabeledSliderRow(label: "Attack",
                                 display: String(format: "%.1f ms", model.project.voiceCleanup.gate.attackMS),
                                 value: voiceCleanupBinding(\.gate.attackMS, target: "audio.voiceCleanup.gate.attack"),
                                 range: 0.1 ... 100, step: 0.1,
                                 onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
                LabeledSliderRow(label: "Release",
                                 display: String(format: "%.0f ms", model.project.voiceCleanup.gate.releaseMS),
                                 value: voiceCleanupBinding(\.gate.releaseMS, target: "audio.voiceCleanup.gate.release"),
                                 range: 1 ... 1000, step: 1,
                                 onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
            }

            Toggle("Compressor", isOn: insertEnabledBinding(\.compressor.bypass, target: "audio.voiceCleanup.compressor.bypass"))
                .accessibilityLabel("Compressor enabled")
            if !model.project.voiceCleanup.compressor.bypass {
                LabeledSliderRow(label: "Threshold",
                                 display: String(format: "%.0f dB", model.project.voiceCleanup.compressor.thresholdDB),
                                 value: voiceCleanupBinding(\.compressor.thresholdDB, target: "audio.voiceCleanup.compressor.threshold"),
                                 range: -60 ... 0, step: 1,
                                 onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
                LabeledSliderRow(label: "Ratio",
                                 display: String(format: "%.1f:1", model.project.voiceCleanup.compressor.ratio),
                                 value: voiceCleanupBinding(\.compressor.ratio, target: "audio.voiceCleanup.compressor.ratio"),
                                 range: 1 ... 20, step: 0.5,
                                 onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
                LabeledSliderRow(label: "Makeup",
                                 display: String(format: "%+.1f dB", model.project.voiceCleanup.compressor.makeupGainDB),
                                 value: voiceCleanupBinding(\.compressor.makeupGainDB, target: "audio.voiceCleanup.compressor.makeup"),
                                 range: -24 ... 24, step: 0.5,
                                 onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
            }

            Toggle("Limiter", isOn: insertEnabledBinding(\.limiter.bypass, target: "audio.voiceCleanup.limiter.bypass"))
                .accessibilityLabel("Limiter enabled")
            if !model.project.voiceCleanup.limiter.bypass {
                LabeledSliderRow(label: "Ceiling",
                                 display: String(format: "%.1f dB", model.project.voiceCleanup.limiter.ceilingDB),
                                 value: voiceCleanupBinding(\.limiter.ceilingDB, target: "audio.voiceCleanup.limiter.ceiling"),
                                 range: -9 ... -0.1, step: 0.1,
                                 onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
                // The limiter is currently a hard clipper (`applyLimiter`), so
                // `LimiterSettings.releaseMS` has no audible effect yet. The
                // Release control is deferred until the look-ahead limiter lands
                // (tracked in the Phase 36 tasks) to avoid exposing a no-op knob.
            }

            LabeledContent("Latency Budget") {
                Text("≤25 ms")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func trackGainRow(_ track: Track) -> some View {
        let input = model.project.trackInput(for: track.id)
        LabeledSliderRow(
            label: track.name,
            spokenLabel: "\(track.name) gain",
            display: formattedGain(input.gain),
            value: trackGainBinding(track: track),
            range: AudioGainMapping.minDecibels...AudioGainMapping.maxDecibels,
            step: AudioGainMapping.sliderStepDecibels,
            captionStyle: .leadingTrailing,
            onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
            resetAction: {
                var input = model.project.trackInput(for: track.id)
                input.gain = 1
                model.setTrackInput(input, coalesced: true)
                model.commitCoalescedUndo()
            })
    }

    private var masterGainBinding: Binding<Double> {
        Binding(
            get: { AudioGainMapping.decibels(fromLinear: Double(model.project.masterGain)) },
            set: { model.setMasterGain(Float(AudioGainMapping.linear(fromDecibels: $0)), coalesced: true) })
    }

    private var loudnessPresetBinding: Binding<LoudnessPreset> {
        Binding(
            get: { model.project.voiceCleanup.loudness.preset },
            set: { newValue in
                model.updateVoiceCleanup("Set Loudness Target") {
                    $0.loudness.preset = newValue
                    if newValue != .custom {
                        $0.loudness.customTargetLUFS = newValue.targetLUFS
                    }
                    // Re-derive the applied gain for the new target so a prior
                    // measurement isn't left rendering to the old target.
                    $0.loudness.refreshAppliedGainFromMeasurement()
                }
            })
    }

    /// Custom-target slider. Like the preset picker, it re-derives the applied
    /// gain from any existing measurement so the rendered loudness tracks the
    /// target the user is dialling in.
    private var customTargetBinding: Binding<Float> {
        Binding(
            get: { model.project.voiceCleanup.loudness.customTargetLUFS },
            set: { newValue in
                model.updateVoiceCleanup(coalesced: true,
                                         target: AnyHashable("audio.voiceCleanup.loudness.target")) {
                    $0.loudness.customTargetLUFS = newValue
                    $0.loudness.refreshAppliedGainFromMeasurement()
                }
            })
    }

    /// Manual Applied Gain slider. Mirrors `applyLoudnessAnalysis`: a non-zero
    /// gain enables normalisation so the value the inspector shows actually
    /// reaches the DSP/export (both are gated on `loudness.enabled`).
    private var appliedGainBinding: Binding<Float> {
        Binding(
            get: { model.project.voiceCleanup.loudness.appliedGainDB },
            set: { newValue in
                model.updateVoiceCleanup(coalesced: true,
                                         target: AnyHashable("audio.voiceCleanup.loudness.gain")) {
                    $0.loudness.appliedGainDB = newValue
                    $0.loudness.enabled = newValue != 0
                }
            })
    }

    private var audioMeterStatus: String {
        if let error = model.audioBus.lastStartError {
            return "Live metering unavailable: \(error)"
        }
        return "Live meter idle."
    }

    private func trackGainBinding(track: Track) -> Binding<Double> {
        Binding(
            get: { AudioGainMapping.decibels(fromLinear: Double(model.project.trackInput(for: track.id).gain)) },
            set: { newValue in
                var input = model.project.trackInput(for: track.id)
                input.gain = Float(AudioGainMapping.linear(fromDecibels: newValue))
                model.setTrackInput(input, coalesced: true)
            })
    }

    private func voiceCleanupBinding(_ keyPath: WritableKeyPath<VoiceCleanupSettings, Float>,
                                     target: String) -> Binding<Float> {
        Binding(
            get: { model.project.voiceCleanup[keyPath: keyPath] },
            set: { newValue in
                model.updateVoiceCleanup(coalesced: true, target: AnyHashable(target)) {
                    $0[keyPath: keyPath] = newValue
                }
            })
    }

    private func insertEnabledBinding(_ bypassKeyPath: WritableKeyPath<VoiceCleanupSettings, Bool>,
                                      target: String) -> Binding<Bool> {
        Binding(
            get: { !model.project.voiceCleanup[keyPath: bypassKeyPath] },
            set: { enabled in
                model.updateVoiceCleanup("Toggle Voice Cleanup Insert", target: AnyHashable(target)) {
                    $0[keyPath: bypassKeyPath] = !enabled
                }
            })
    }

    private func formattedGain(_ linear: Float) -> String {
        // Show dB so the value matches what a sound engineer expects; clamp at
        // −60 dB to avoid a `-inf` label at zero gain.
        if linear <= 0.001 { return "−∞ dB" }
        let db = 20 * log10(Double(linear))
        return String(format: "%+.1f dB", db)
    }
}

/// Two-channel peak + RMS meter rendered as horizontal bars. Hold-line / decay
/// animation is left to Phase 36 / 46 — for this spec we render the live
/// snapshot value directly.
private struct MeterStrip: View {
    let snapshot: AudioMeterSnapshot

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 2) {
                channelBar(peak: snapshot.peakLeft, rms: snapshot.rmsLeft, width: geo.size.width)
                channelBar(peak: snapshot.peakRight, rms: snapshot.rmsRight, width: geo.size.width)
            }
        }
    }

    @ViewBuilder
    private func channelBar(peak: Float, rms: Float, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.quaternary)
            RoundedRectangle(cornerRadius: 2)
                .fill(.tint.opacity(0.5))
                .frame(width: width * CGFloat(min(1, max(0, peak))))
            RoundedRectangle(cornerRadius: 2)
                .fill(.tint)
                .frame(width: width * CGFloat(min(1, max(0, rms))))
        }
    }
}

// MARK: - Audio-clip fade inspector (per-clip envelope)

/// Per-clip fade-in / fade-out controls for an **audio** clip selection.
/// Rendered inside `InspectorView`'s clip section so it sits next to opacity
/// rather than down in the global audio section — fades are clip identity,
/// not bus state.
struct AudioClipFadesInspectorView: View {
    @Bindable var model: EditorModel
    let clip: Clip

    /// Cap fades at the clip's output duration (retimed); sub-frame durations
    /// would round to zero on most clip lengths anyway, so 0…clipDuration is
    /// the useful range.
    private var maxFadeSeconds: Double {
        max(0.01, clip.outputDuration.seconds)
    }

    var body: some View {
        Section("Audio Fades") {
            fadeRow(label: "Fade In", value: fadeBinding(\.fadeIn))
            fadeRow(label: "Fade Out", value: fadeBinding(\.fadeOut))
        }
    }

    @ViewBuilder
    private func fadeRow(label: String, value: Binding<Double>) -> some View {
        LabeledSliderRow(
            label: label,
            spokenLabel: "\(label) seconds",
            display: String(format: "%.2f s", value.wrappedValue),
            value: value,
            range: 0...maxFadeSeconds,
            step: 0.01,
            captionStyle: .leadingTrailing,
            onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })
    }

    /// Binding for one fade edge in seconds, built inline (the same shape as
    /// `masterGainBinding`) so the setter's main-actor isolation is inferred
    /// rather than forwarded through an annotated parameter — the latter makes
    /// the Swift 6.3 compiler crash emitting the `@MainActor`→`@Sendable`
    /// reabstraction thunk for `Binding.set`.
    private func fadeBinding(_ keyPath: WritableKeyPath<VolumeEnvelope, CMTime>) -> Binding<Double> {
        Binding(
            get: {
                let seconds = clip.volumeEnvelope[keyPath: keyPath].seconds
                return seconds.isFinite ? min(seconds, maxFadeSeconds) : 0
            },
            set: { newValue in
                var envelope = clip.volumeEnvelope
                envelope[keyPath: keyPath] = CMTime(seconds: newValue, preferredTimescale: 600)
                model.setClipVolumeEnvelope(envelope, clipID: clip.id, coalesced: true)
            })
    }
}
