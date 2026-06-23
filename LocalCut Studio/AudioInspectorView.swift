import SwiftUI
import Foundation
import AVFoundation

/// Maps the audio gain sliders between linear amplitude (what the model stores)
/// and decibels (what the slider travels in), so equal travel is equal dB — the
/// log mapping feature-audio-master-bus's design specified. A linear 0…2 slider
/// cramped all useful control around unity and spent its lower half on
/// inaudible levels; a −60…+6 dB fader gives fine control where mixing happens.
nonisolated enum AudioGainMapping {
    static let minDecibels: Double = -60
    static let maxDecibels: Double = 6

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
            VStack(alignment: .leading, spacing: 4) {
                Text("Master Gain  \(formattedGain(model.project.masterGain))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Master gain \(formattedGain(model.project.masterGain))")
                Slider(
                    value: masterGainBinding,
                    in: AudioGainMapping.minDecibels...AudioGainMapping.maxDecibels,
                    step: 0.5,
                    onEditingChanged: { editing in
                        // Drag end commits the coalesced gesture so a quick
                        // click→drag→release maps to exactly one undo step
                        // instead of waiting on the 250 ms debounce timer.
                        if !editing { model.commitCoalescedUndo() }
                    })
                    .accessibilityLabel("Master gain")
                    .accessibilityValue(formattedGain(model.project.masterGain))
            }
            .contextMenu {
                Button("Reset", systemImage: "arrow.uturn.backward") {
                    model.setMasterGain(1, coalesced: true)
                    model.commitCoalescedUndo()
                }
            }

            // SwiftUI.TimelineView (fully qualified — the repo also defines
            // a `TimelineView` struct for the editor's timeline lane, which
            // would otherwise win name resolution and route this call to its
            // `init(model:)` instead). Driving repaints on a fixed cadence
            // lets audio-thread tap writes flow through to the meter without
            // forcing the bus to mirror its snapshot onto an `@Observable`
            // property on every audio block.
            //
            // The live bus isn't wired into the `AVPlayer` preview path until
            // Phase 36, so until then the snapshot stays silent. Two flat
            // bars would look like broken audio rather than "not connected"
            // — surface a clear placeholder while `isLiveRunning == false`
            // and only render the live meter once the bus is engaged.
            if model.audioBus.isLiveRunning {
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    MeterStrip(snapshot: model.audioBus.meterSnapshot)
                        .frame(height: 18)
                        .accessibilityLabel("Master output meter")
                }
            } else {
                Text("Live metering available once the bus is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Live metering not connected")
            }

            ForEach(model.project.audioTracks) { track in
                trackGainRow(track)
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
            step: 0.5,
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

    private func trackGainBinding(track: Track) -> Binding<Double> {
        Binding(
            get: { AudioGainMapping.decibels(fromLinear: Double(model.project.trackInput(for: track.id).gain)) },
            set: { newValue in
                var input = model.project.trackInput(for: track.id)
                input.gain = Float(AudioGainMapping.linear(fromDecibels: newValue))
                model.setTrackInput(input, coalesced: true)
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

    /// Cap fades at the clip's duration; sub-frame durations would round to
    /// zero on most clip lengths anyway, so 0…clipDuration is the useful range.
    private var maxFadeSeconds: Double {
        max(0.01, clip.duration.seconds)
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
