#if DEBUG
import SwiftUI
import AVFoundation
import LocalCutCore

private enum RecorderHarnessPhase: String {
    case idle = "Idle"
    case recording = "Recording"
    case paused = "Paused"
    case stopped = "Stopped"
}

private let recorderHarnessShortcutModifiers: EventModifiers = []

struct RecorderUITestHarnessView: View {
    @State private var model = EditorModel()
    @State private var phase: RecorderHarnessPhase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recorder UX Harness")
                .font(.title2)
                .fontWeight(.semibold)
                .accessibilityIdentifier("uitest-recorder-harness")

            VStack(alignment: .leading, spacing: 8) {
                Text(phase.rawValue)
                    .accessibilityLabel(phase.rawValue)
                    .accessibilityIdentifier("uitest-recorder-state-\(phase.identifier)")
                Text(gapLabel)
                    .monospacedDigit()
                    .accessibilityLabel(gapLabel)
                    .accessibilityIdentifier(gapIdentifier)
                Text(model.statusMessage)
                    .lineLimit(2)
                    .accessibilityLabel(model.statusMessage)
                    .accessibilityIdentifier(statusIdentifier)
            }

            HStack(spacing: 10) {
                Button("Start Recording") {
                    startRecording()
                }
                .accessibilityIdentifier("uitest-start-recording")
                .keyboardShortcut("1", modifiers: recorderHarnessShortcutModifiers)
                .disabled(phase == .recording)

                Button("Pause") {
                    pauseRecording()
                }
                .accessibilityIdentifier("uitest-pause-recording")
                .keyboardShortcut("2", modifiers: recorderHarnessShortcutModifiers)
                .disabled(phase != .recording)

                Button("Resume") {
                    resumeRecording()
                }
                .accessibilityIdentifier("uitest-resume-recording")
                .keyboardShortcut("3", modifiers: recorderHarnessShortcutModifiers)
                .disabled(phase != .paused)

                Button("Stop") {
                    stopRecording()
                }
                .accessibilityIdentifier("uitest-stop-recording")
                .keyboardShortcut("4", modifiers: recorderHarnessShortcutModifiers)
                .disabled(phase != .recording)
            }

            Button("Collapse Gaps") {
                model.collapseRecordingGap()
            }
            .accessibilityIdentifier("uitest-collapse-gaps")
            .keyboardShortcut("5", modifiers: recorderHarnessShortcutModifiers)
            .disabled(model.lastRecordingSlots.isEmpty)
        }
        .padding(24)
    }

    private var gapSeconds: Double {
        guard let track = model.project.videoTracks.first else { return 0 }
        let clips = track.clips.sorted { $0.timelineStart < $1.timelineStart }
        guard clips.count >= 2 else { return 0 }
        return max(0, (clips[1].timelineStart - clips[0].timelineEnd).seconds)
    }

    private var gapLabel: String {
        String(format: "Timeline gap: %.1f s", gapSeconds)
    }

    private var gapIdentifier: String {
        gapSeconds < 0.05 ? "uitest-timeline-gap-0-0" : "uitest-timeline-gap-3-0"
    }

    private var statusIdentifier: String {
        model.statusMessage == "Recording gaps collapsed."
            ? "uitest-status-gaps-collapsed"
            : "uitest-status-message"
    }

    private func startRecording() {
        model.isRecording = true
        model.isPaused = false
        model.recordingSourceCount = 1
        model.statusMessage = "Recording..."
        phase = .recording
    }

    private func pauseRecording() {
        model.isRecording = false
        model.isPaused = true
        model.statusMessage = "Recording paused."
        phase = .paused
    }

    private func resumeRecording() {
        model.isRecording = true
        model.isPaused = false
        model.statusMessage = "Recording..."
        phase = .recording
    }

    private func stopRecording() {
        model.isRecording = false
        model.isPaused = false
        model.recordingSourceCount = 0
        seedGappedRecording()
        model.statusMessage = "Recording stopped."
        phase = .stopped
    }

    private func seedGappedRecording() {
        let mediaID = UUID()
        let duration = CMTime(seconds: 2, preferredTimescale: 600)
        let first = Clip(mediaID: mediaID, sourceStart: .zero, duration: duration, timelineStart: .zero)
        let second = Clip(
            mediaID: mediaID,
            sourceStart: .zero,
            duration: duration,
            timelineStart: CMTime(seconds: 5, preferredTimescale: 600))
        let track = Track(name: "Screen", kind: .video)
        track.clips = [first, second]
        model.project.videoTracks = [track]
        model.lastRecordingSlots = [
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .display, trackKind: .video, chunkIndex: 0),
                trackID: track.id,
                trackIndex: 0,
                clipID: first.id,
                mediaID: first.mediaID,
                timelineStart: first.timelineStart),
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .display, trackKind: .video, chunkIndex: 1),
                trackID: track.id,
                trackIndex: 0,
                clipID: second.id,
                mediaID: second.mediaID,
                timelineStart: second.timelineStart),
        ]
    }
}

private extension RecorderHarnessPhase {
    var identifier: String {
        rawValue.lowercased()
    }
}
#endif
