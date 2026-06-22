import SwiftUI
import Foundation
import AVFoundation

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
                    in: 0...2,
                    step: 0.01,
                    onEditingChanged: { editing in
                        // Drag end commits the coalesced gesture so a quick
                        // click→drag→release maps to exactly one undo step
                        // instead of waiting on the 250 ms debounce timer.
                        if !editing { model.commitCoalescedUndo() }
                    })
                    .accessibilityLabel("Master gain")
                    .accessibilityValue(formattedGain(model.project.masterGain))
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(track.name)
                    .font(.caption.bold())
                Spacer()
                Text(formattedGain(input.gain))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: trackGainBinding(track: track),
                in: 0...2,
                step: 0.01,
                onEditingChanged: { editing in
                    if !editing { model.commitCoalescedUndo() }
                })
                .accessibilityLabel("\(track.name) gain")
                .accessibilityValue(formattedGain(input.gain))
        }
    }

    private var masterGainBinding: Binding<Double> {
        Binding(
            get: { Double(model.project.masterGain) },
            set: { model.setMasterGain(Float($0), coalesced: true) })
    }

    private func trackGainBinding(track: Track) -> Binding<Double> {
        Binding(
            get: { Double(model.project.trackInput(for: track.id).gain) },
            set: { newValue in
                var input = model.project.trackInput(for: track.id)
                input.gain = Float(newValue)
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
            fadeRow(label: "Fade In",
                    seconds: Double(clip.volumeEnvelope.fadeIn.seconds),
                    set: { newValue in
                        var envelope = clip.volumeEnvelope
                        envelope.fadeIn = CMTime(seconds: newValue, preferredTimescale: 600)
                        model.setClipVolumeEnvelope(envelope, clipID: clip.id, coalesced: true)
                    })
            fadeRow(label: "Fade Out",
                    seconds: Double(clip.volumeEnvelope.fadeOut.seconds),
                    set: { newValue in
                        var envelope = clip.volumeEnvelope
                        envelope.fadeOut = CMTime(seconds: newValue, preferredTimescale: 600)
                        model.setClipVolumeEnvelope(envelope, clipID: clip.id, coalesced: true)
                    })
        }
    }

    @ViewBuilder
    private func fadeRow(label: String,
                         seconds: Double,
                         set: @escaping @Sendable (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold())
                Spacer()
                Text(String(format: "%.2f s", seconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { seconds.isFinite ? min(seconds, maxFadeSeconds) : 0 },
                    set: set),
                in: 0...maxFadeSeconds,
                step: 0.01,
                onEditingChanged: { editing in
                    if !editing { model.commitCoalescedUndo() }
                })
                .accessibilityLabel("\(label) seconds")
                .accessibilityValue(String(format: "%.2f s", seconds))
        }
    }
}
