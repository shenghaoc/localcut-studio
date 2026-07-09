import Foundation
import AVFoundation
import Speech
import OSLog
import LocalCutCore

// MARK: - Auto Caption State

/// State for the auto-caption workflow, tracked on EditorModel.
struct AutoCaptionState {
    /// Current availability for the selected locale.
    var availability: TranscriptionAvailability = .notDetermined
    /// The chosen locale for transcription.
    var chosenLocale: TranscriptionLocaleChoice?
    /// User override locale (from the picker).
    var userOverrideLocale: Locale?
    /// Whether transcription is currently running.
    var isTranscribing = false
    /// Current transcription progress.
    var progress: TranscriptionProgress?
    /// Active proposal for review, if any.
    var proposal: CaptionTranscriptionProposal?
    /// Whether the review modal is presented.
    var isReviewPresented = false
    /// Warnings from the last transcription.
    var warnings: [TranscriptionWarning] = []
    /// Cancellation token for the current transcription.
    var cancellationToken: CancellationToken?
    /// Task handle for the current transcription (for cancellation tracking).
    var transcriptionTask: Task<Void, Never>?
}

// MARK: - EditorModel Auto Captions Extension

extension EditorModel {

    private static let autoCaptionLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LocalCutStudio",
        category: "AutoCaptions"
    )

    // MARK: - Availability

    /// Whether auto captions are available for the current selection.
    var isAutoCaptionAvailable: Bool {
        autoCaptionState.availability.isReady
    }

    /// Status message for the auto-caption feature.
    var autoCaptionStatusMessage: String? {
        autoCaptionState.availability.displayMessage
    }

    /// Runs the availability probe for the given locale.
    func checkAutoCaptionAvailability() async {
        let locale = resolvedAutoCaptionLocale()
        autoCaptionState.chosenLocale = locale
        let availability = await TranscriptionService.shared.checkAvailability(locale: locale.locale)
        autoCaptionState.availability = availability
        Self.autoCaptionLogger.info("Availability for \(locale.locale.identifier): \(String(describing: availability))")
    }

    /// Resolves the locale using the priority chain.
    private func resolvedAutoCaptionLocale() -> TranscriptionLocaleChoice {
        // 1. User override
        if let override = autoCaptionState.userOverrideLocale {
            return TranscriptionLocaleChoice(locale: override, source: .userOverride)
        }

        // 2. Asset metadata — TODO: Extract language from AVAsset metadata when available
        if let clip = selectedClip,
           let media = project.media(for: clip.mediaID) {
            _ = media // silence unused warning; metadata extraction not yet implemented
        }

        // 3. System locale fallback
        return TranscriptionLocaleChoice(locale: Locale.current, source: .systemFallback)
    }

    /// Sets the user override locale and re-runs the availability probe.
    /// Ignored if a transcription is currently in progress.
    func setAutoCaptionLocale(_ locale: Locale?) {
        guard !autoCaptionState.isTranscribing else {
            statusMessage = "Cannot change language while transcription is in progress."
            return
        }
        autoCaptionState.userOverrideLocale = locale
        Task { @MainActor in
            await checkAutoCaptionAvailability()
        }
    }

    // MARK: - Transcription

    /// Starts the transcription workflow for the selected clip.
    func startAutoCaptionTranscription() {
        guard let clip = selectedClip else {
            statusMessage = "No clip selected for transcription."
            return
        }
        guard let media = project.media(for: clip.mediaID) else {
            statusMessage = "Could not resolve media for the selected clip."
            return
        }
        guard isAutoCaptionAvailable else {
            statusMessage = autoCaptionState.availability.displayMessage
            return
        }

        let locale = resolvedAutoCaptionLocale()
        autoCaptionState.chosenLocale = locale
        autoCaptionState.isTranscribing = true
        autoCaptionState.progress = nil
        autoCaptionState.warnings = []
        autoCaptionState.proposal = nil

        let token = CancellationToken()
        autoCaptionState.cancellationToken = token

        let request = CaptionTranscriptionRequest(
            clipID: clip.id,
            sourceAssetURL: media.url,
            sourceStart: clip.sourceStart,
            duration: clip.duration,
            timelineStart: clip.timelineStart,
            locale: locale.locale,
            speedCurve: clip.speedCurve,
            sourceDuration: clip.duration
        )

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let proposal = try await TranscriptionService.shared.transcribe(
                    request: request,
                    asset: media.asset,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.autoCaptionState.progress = progress
                        }
                    },
                    cancellation: token
                )

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.autoCaptionState.isTranscribing = false
                    self.autoCaptionState.progress = nil
                    self.autoCaptionState.cancellationToken = nil
                    self.autoCaptionState.transcriptionTask = nil

                    if proposal.lines.isEmpty {
                        self.autoCaptionState.warnings = proposal.warnings
                        self.statusMessage = "No speech detected in the selected clip."
                    } else {
                        // Set proposal and present review in one atomic update to avoid flicker
                        self.autoCaptionState.proposal = proposal
                        self.autoCaptionState.isReviewPresented = true
                        self.statusMessage = "Transcription complete. Review \(proposal.lines.count) proposed caption(s)."
                    }
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.autoCaptionState.isTranscribing = false
                    self.autoCaptionState.progress = nil
                    self.autoCaptionState.cancellationToken = nil
                    self.autoCaptionState.transcriptionTask = nil
                    self.statusMessage = "Transcription cancelled."
                }
            } catch {
                Self.autoCaptionLogger.error("Transcription failed for clip \(clip.id): \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.autoCaptionState.isTranscribing = false
                    self.autoCaptionState.progress = nil
                    self.autoCaptionState.cancellationToken = nil
                    self.autoCaptionState.transcriptionTask = nil
                    self.statusMessage = "Transcription failed: \(error.localizedDescription)"
                }
            }
        }
        autoCaptionState.transcriptionTask = task
    }

    /// Cancels the current transcription.
    /// Only signals cancellation via the token; the Task's own completion handler manages state cleanup.
    func cancelAutoCaptionTranscription() {
        autoCaptionState.cancellationToken?.cancel()
        autoCaptionState.transcriptionTask?.cancel()
        // Do NOT clear isTranscribing/progress/cancellationToken here.
        // The running Task's catch/cancel path handles cleanup to avoid race conditions.
    }

    // MARK: - Review

    /// Presents the review modal for the current proposal.
    func presentAutoCaptionReview() {
        guard autoCaptionState.proposal != nil else {
            statusMessage = "No transcription proposal available to review."
            return
        }
        autoCaptionState.isReviewPresented = true
    }

    /// Dismisses the review modal without applying.
    func dismissAutoCaptionReview() {
        autoCaptionState.isReviewPresented = false
        autoCaptionState.proposal = nil
        statusMessage = "Auto-caption review cancelled."
    }

    /// Toggles acceptance of a single proposal line.
    func toggleAutoCaptionLine(_ lineID: UUID) {
        guard var proposal = autoCaptionState.proposal,
              let index = proposal.lines.firstIndex(where: { $0.id == lineID }) else { return }
        proposal.lines[index].isAccepted.toggle()
        proposal.lines[index].isSkipped = false
        autoCaptionState.proposal = proposal
    }

    /// Skips a single proposal line.
    func skipAutoCaptionLine(_ lineID: UUID) {
        guard var proposal = autoCaptionState.proposal,
              let index = proposal.lines.firstIndex(where: { $0.id == lineID }) else { return }
        proposal.lines[index].isSkipped = true
        proposal.lines[index].isAccepted = false
        autoCaptionState.proposal = proposal
    }

    /// Accepts all proposal lines.
    func acceptAllAutoCaptionLines() {
        guard var proposal = autoCaptionState.proposal else { return }
        for i in proposal.lines.indices {
            proposal.lines[i].isAccepted = true
            proposal.lines[i].isSkipped = false
        }
        autoCaptionState.proposal = proposal
    }

    /// Applies the accepted lines to the caption track as a single undoable transaction.
    func applyAutoCaptions() {
        guard let proposal = autoCaptionState.proposal else { return }
        let acceptedLines = proposal.acceptedLines

        guard !acceptedLines.isEmpty else {
            statusMessage = "No caption lines were accepted."
            autoCaptionState.isReviewPresented = false
            autoCaptionState.proposal = nil
            return
        }

        // Apply all accepted lines in a single undoable transaction
        performUndoable("Apply Auto Captions") {
            let trackName = "Auto Captions"
            let track: CaptionTrack

            if let existingTrack = project.captionTracks.first(where: { $0.name == trackName }) {
                track = existingTrack
            } else {
                let newTrack = CaptionTrack(name: trackName)
                project.captionTracks.append(newTrack)
                track = newTrack
            }

            for line in acceptedLines {
                track.addLine(line)
            }
            scheduleRebuild()
        }

        statusMessage = "Applied \(acceptedLines.count) auto-caption line(s)."

        autoCaptionState.isReviewPresented = false
        autoCaptionState.proposal = nil
    }

    // MARK: - Locale Picker

    /// Available locales for on-device speech recognition.
    var availableAutoCaptionLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
    }

    /// The display name for a locale in the picker.
    func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
