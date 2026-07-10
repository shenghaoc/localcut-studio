import SwiftUI
import AVFoundation
import LocalCutCore

// MARK: - Auto Caption Review Modal

/// Modal for reviewing proposed auto-caption lines before applying them.
struct AutoCaptionReviewView: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Warnings
            if let proposal = model.autoCaptionState.proposal,
               !proposal.warnings.isEmpty {
                warningsSection(proposal.warnings)
                Divider()
            }

            // Progress during transcription
            if model.autoCaptionState.isTranscribing {
                progressSection
                Divider()
            }

            // Lines list
            if let proposal = model.autoCaptionState.proposal {
                linesSection(proposal)
            }

            Divider()

            // Footer actions
            footerSection
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto Caption Review")
                    .font(.headline)

                if let locale = model.autoCaptionState.chosenLocale {
                    Text("Language: \(model.displayName(for: locale.locale))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let proposal = model.autoCaptionState.proposal {
                let accepted = proposal.lines.filter { $0.isAccepted }.count
                let total = proposal.lines.count
                Text("\(accepted)/\(total) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Warnings

    private func warningsSection(_ warnings: [TranscriptionWarning]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(warnings.indices, id: \.self) { index in
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warnings[index].displayMessage)
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 8) {
            if let progress = model.autoCaptionState.progress {
                ProgressView(value: progress.fractionComplete) {
                    Text("Transcribing window \(progress.currentWindow) of \(progress.totalWindows)...")
                        .font(.subheadline)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing transcription...")
                    .font(.subheadline)
            }

            Button("Cancel") {
                model.cancelAutoCaptionTranscription()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Lines

    private func linesSection(_ proposal: CaptionTranscriptionProposal) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(proposal.lines) { line in
                    proposalLineRow(line)
                }
            }
            .padding()
        }
    }

    private func proposalLineRow(_ line: CaptionProposalLine) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Accept/skip toggle
            VStack(spacing: 4) {
                Button {
                    model.toggleAutoCaptionLine(line.id)
                } label: {
                    Image(systemName: line.isAccepted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(line.isAccepted ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(line.isAccepted ? "Deselect line" : "Select line")

                Button {
                    model.skipAutoCaptionLine(line.id)
                } label: {
                    Image(systemName: line.isSkipped ? "xmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(line.isSkipped ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(line.isSkipped ? "Unskip line" : "Skip line")
            }

            // Line content
            VStack(alignment: .leading, spacing: 4) {
                Text(line.proposedLine.text)
                    .font(.body)
                    .strikethrough(line.isSkipped)

                HStack {
                    Text(formatTime(line.proposedLine.range.start))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("→")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatTime(line.proposedLine.range.start + line.proposedLine.range.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let words = line.proposedLine.words {
                        Text("(\(words.count) words)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Scrub to this line
            Button {
                model.seek(toSeconds: line.proposedLine.range.start.seconds)
            } label: {
                Image(systemName: "play.circle")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scrub to line")
        }
        .padding(8)
        .background(line.isSkipped ? Color.red.opacity(0.05) : Color.clear)
        .cornerRadius(8)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Cancel") {
                model.dismissAutoCaptionReview()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Accept All") {
                model.acceptAllAutoCaptionLines()
            }
            .buttonStyle(.bordered)

            Button("Apply Selected") {
                model.applyAutoCaptions()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.autoCaptionState.proposal?.acceptedLines.isEmpty ?? true)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Helpers

    private func formatTime(_ time: CMTime) -> String {
        guard time.isNumeric else { return "--:--" }
        let seconds = time.seconds
        let minutes = Int(seconds) / 60
        let secs = seconds - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, secs)
    }
}

// MARK: - Auto Caption Toolbar Button

/// Toolbar button that triggers auto-caption availability check and transcription.
struct AutoCaptionToolbarButton: View {
    @Bindable var model: EditorModel
    @State private var isLocalePickerPresented = false

    var body: some View {
        Menu {
            if model.isAutoCaptionAvailable {
                Button("Transcribe Selected Clip") {
                    model.startAutoCaptionTranscription()
                }
                .disabled(model.selectedClip == nil)

                Divider()

                Button("Select Language...") {
                    isLocalePickerPresented = true
                }
            } else {
                Text(model.autoCaptionStatusMessage ?? "Auto captions unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Check Availability") {
                    Task {
                        await model.checkAutoCaptionAvailability()
                    }
                }

                Button("Select Language...") {
                    isLocalePickerPresented = true
                }
            }
        } label: {
            Label("Auto Captions", systemImage: "text.badge.plus")
        }
        .disabled(!model.isAutoCaptionAvailable && model.autoCaptionState.availability != .notDetermined)
        .sheet(isPresented: $isLocalePickerPresented) {
            AutoCaptionLocalePicker(model: model, isPresented: $isLocalePickerPresented)
        }
    }
}

// MARK: - Locale Picker

/// Sheet for selecting the transcription language.
struct AutoCaptionLocalePicker: View {
    @Bindable var model: EditorModel
    @Binding var isPresented: Bool
    @State private var selectedLocale: Locale?

    var body: some View {
        VStack(spacing: 16) {
            Text("Select Transcription Language")
                .font(.headline)

            Text("Choose the language spoken in the clip. The recognizer will use this language for transcription.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Picker("Language", selection: $selectedLocale) {
                Text("System Default (\(model.displayName(for: Locale.current)))")
                    .tag(nil as Locale?)

                ForEach(model.availableAutoCaptionLocales, id: \.identifier) { locale in
                    Text(model.displayName(for: locale))
                        .tag(locale as Locale?)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    model.setAutoCaptionLocale(selectedLocale)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            selectedLocale = model.autoCaptionState.userOverrideLocale
        }
    }
}
