import SwiftUI

/// Caption layout for ``LabeledSliderRow``.
enum SliderCaptionStyle {
    /// `Label  value` on one secondary line, hidden from VoiceOver (the slider
    /// carries the spoken label + value). Used by colour, beauty, transitions.
    case inline
    /// Bold leading label with the value trailing on the same line, read by
    /// VoiceOver as part of the row. Used by the audio gain / fade rows.
    case leadingTrailing
}

/// A labelled slider row shared across the inspector sections.
///
/// Consolidates the five copy-pasted slider builders (colour grade, beauty,
/// transition duration, track gain, clip fades) behind one view, so the caption
/// formatting, `monospacedDigit`, and the accessibility-label/value pairing live
/// in exactly one place — the pattern Palette's accessibility journal requires
/// for custom-layout sliders (hide the redundant visual label, voice the slider).
///
/// Generic over the slider's floating-point value so both `Float` (colour /
/// beauty) and `Double` (audio / transition) bindings adopt it unchanged.
struct LabeledSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    /// Visible label text.
    let label: String
    /// Spoken VoiceOver label; defaults to `label` but lets callers spell out
    /// abbreviations (e.g. "Temp offset" → "Temperature Offset").
    var spokenLabel: String? = nil
    /// Pre-formatted value string shown in the caption.
    let display: String
    /// Spoken accessibility value; defaults to `display` when the caption and
    /// the announced value match.
    var spokenValue: String? = nil
    @Binding var value: Value
    let range: ClosedRange<Value>
    /// Discrete step; `nil` makes the slider continuous.
    var step: Value.Stride? = nil
    var captionStyle: SliderCaptionStyle = .inline
    /// Forwarded to the underlying `Slider`; the gain/fade rows use it to commit
    /// a coalesced undo step on drag end.
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: captionSpacing) {
            caption
            slider
                .accessibilityLabel(spokenLabel ?? label)
                .accessibilityValue(spokenValue ?? display)
        }
    }

    private var captionSpacing: CGFloat? {
        switch captionStyle {
        case .inline: nil
        case .leadingTrailing: 4
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch captionStyle {
        case .inline:
            Text("\(label)  \(display)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .leadingTrailing:
            HStack {
                Text(label).font(.caption.bold())
                Spacer()
                Text(display)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
        } else {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
    }
}
