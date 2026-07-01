import SwiftUI
import CoreMedia
import LocalCutCore

// MARK: - Silence Review Sheet

/// Modal that lists proposed silence cuts with per-region apply/skip and
/// a scrubbable preview. Cancelling leaves the project unchanged.
struct SilenceReviewSheet: View {
    @Bindable var model: EditorModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Silence Detection")
                .font(.headline)

            if model.silenceProposals.isEmpty {
                Text("No silences detected.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.silenceProposals.filter(\.isSelected).count) of \(model.silenceProposals.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    ForEach(model.silenceProposals) { proposal in
                        proposalRow(proposal)
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    model.cancelSilenceReview()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Apply Selected") {
                    model.applySelectedSilenceProposals()
                    isPresented = false
                }
                .disabled(!model.silenceProposals.contains(where: \.isSelected))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private func proposalRow(_ proposal: ProposedCut) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { proposal.isSelected },
                set: { _ in model.toggleSilenceProposal(proposal.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Select silence at \(timecodeString(proposal.silenceRange.start))")

            VStack(alignment: .leading, spacing: 2) {
                Text(timecodeString(proposal.silenceRange.start) + " – " + timecodeString(proposal.silenceRange.end))
                    .font(.body.monospacedDigit())
                HStack(spacing: 8) {
                    Text(String(format: "%.1fs", proposal.silenceRange.duration.seconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(proposal.suggestedAction == .trim ? "Trim" : "Split")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                model.currentTime = proposal.silenceRange.start.seconds
            } label: {
                Image(systemName: "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Scrub to this silence")
            .accessibilityLabel("Preview silence at \(timecodeString(proposal.silenceRange.start))")
        }
    }

    private func timecodeString(_ time: CMTime) -> String {
        let total = max(0, time.seconds)
        let mins = Int(total) / 60
        let secs = Int(total) % 60
        let frac = Int((total - Double(Int(total))) * 10)
        return String(format: "%d:%02d.%d", mins, secs, frac)
    }
}
