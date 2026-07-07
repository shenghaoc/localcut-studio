import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore

/// Focused state container for capture/recording functionality.
/// Extracted from EditorModel to improve cohesion and testability.
@Observable
@MainActor
final class CaptureState {
    // MARK: - Recording lifecycle

    var isRecorderPresented = false
    var isStartingRecording = false
    var isRecording = false
    var isPausingRecording = false
    var isStoppingRecording = false
    var hideFloatingPanelWhileRecording = false
    var recordingStartedAt: Date?
    var recordingElapsedSeconds: Double = 0
    var recordingDiskFreeBytes: Int64?
    var recordingDiskWarning: RecordingDiskWarning?
    var recordingSourceCount: Int = 0
    var recordingBackpressureCount: Int = 0
    var recordingIncludesMicrophone = false
    var recordingMicLevel: Float = 0
    var recordingLiveMonitorLatencyMs: Double = 0
    var recoveredCaptureSessions: [CaptureSessionResult] = []

    // MARK: - Recorder UX (Phase 42)

    var isCountdownActive = false
    var countdownSeconds = 3
    var countdownRemaining = 0
    var isPaused = false
    var hasLastRecordingTake = false

    // MARK: - PiP

    var activePiPPreset: PiPPreset?

    // MARK: - Nonisolated state

    @ObservationIgnored nonisolated(unsafe) var recordingsFolderAccessURL: URL?
    @ObservationIgnored nonisolated(unsafe) var recordingMonitorTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var recordingPausedDuration: TimeInterval = 0
    @ObservationIgnored nonisolated(unsafe) var pauseStartedAt: Date?
    @ObservationIgnored nonisolated(unsafe) var lastRecordingRequest: CaptureStartRequest?
    @ObservationIgnored var lastRecordingSlots: [RecordingSlot] = []
    @ObservationIgnored var retakeTimelinePositions: [RecordingSlotKey: CMTime] = [:]
    @ObservationIgnored var retakeUndoBefore: ProjectState?
    @ObservationIgnored var retakePreviousSlots: [RecordingSlot] = []
    @ObservationIgnored var retakeTrackIndices: [RecordingSlotKey: Int] = [:]
    @ObservationIgnored var lastRecordingPiPPreset: PiPPreset?

    // MARK: - Floating panel

    @ObservationIgnored let floatingPanelController = FloatingPanelController()

    // MARK: - Computed properties

    var canCollapseRecordingGaps: Bool {
        hasLastRecordingTake && !isRecording && !isPaused
            && !isStartingRecording && !isPausingRecording && !isStoppingRecording
    }

    var canRetakeRecording: Bool {
        hasLastRecordingTake && lastRecordingRequest != nil
            && !isRecording && !isPaused
            && !isStartingRecording && !isPausingRecording && !isStoppingRecording
    }
}
