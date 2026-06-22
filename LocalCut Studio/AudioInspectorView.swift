import SwiftUI
import Foundation
import AVFoundation

/// Inspector section for the audio master bus (P16). Renders the master gain
/// slider and a two-channel peak + RMS meter driven by the bus's
/// `AudioMeterSnapshot`. Phase 36's insert toggles (denoiser, gate, compressor,
/// limiter) will land beneath the meter; the section keeps that space.
struct AudioInspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section("Audio") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Master Gain  \(formattedGain(model.project.masterGain))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Master gain \(formattedGain(model.project.masterGain))")
                Slider(value: masterGainBinding, in: 0...2, step: 0.01)
                    .accessibilityLabel("Master gain")
                    .accessibilityValue(formattedGain(model.project.masterGain))
            }

            MeterStrip(snapshot: model.audioBus.meterSnapshot)
                .frame(height: 18)
                .accessibilityLabel("Master output meter")
        }
    }

    private var masterGainBinding: Binding<Double> {
        Binding(
            get: { Double(model.project.masterGain) },
            set: { model.setMasterGain(Float($0), coalesced: true) })
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
