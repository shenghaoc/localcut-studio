import Foundation
import CoreGraphics
import CoreMedia
import LocalCutCore

nonisolated enum CaptureEngineError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case noCaptureSources
    case targetUnavailable
    case writerRejectedInput(String)
    case writerStartFailed(String)
    case writerFinishFailed(String)
    case screenRecordingDenied
    case cameraPermissionDenied
    case microphonePermissionDenied
    case cameraUnavailable
    case microphoneUnavailable
    case captureSessionFailed(String)
    case manifestWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "A recording is already running."
        case .notRecording:
            "No recording is running."
        case .noCaptureSources:
            "Select at least one recording source."
        case .targetUnavailable:
            "The selected screen, window, or app is no longer available."
        case .writerRejectedInput(let source):
            "The recorder could not add a writer input for \(source)."
        case .writerStartFailed(let reason):
            "The recorder could not start writing: \(reason)"
        case .writerFinishFailed(let reason):
            "The recorder could not finish writing: \(reason)"
        case .screenRecordingDenied:
            "Screen recording permission is required. Enable LocalCut Studio in System Settings."
        case .cameraPermissionDenied:
            "Camera permission is required. Enable LocalCut Studio in System Settings."
        case .microphonePermissionDenied:
            "Microphone permission is required. Enable LocalCut Studio in System Settings."
        case .cameraUnavailable:
            "The selected camera is unavailable."
        case .microphoneUnavailable:
            "The selected microphone is unavailable."
        case .captureSessionFailed(let reason):
            "Capture failed: \(reason)"
        case .manifestWriteFailed(let reason):
            "Could not update the recording manifest: \(reason)"
        }
    }
}

nonisolated struct CaptureSourceOption: Identifiable, Hashable {
    let id: String
    var title: String
    var subtitle: String
    var target: CaptureTarget
    var width: Int
    var height: Int
}

nonisolated enum CaptureTarget: Hashable, Sendable {
    case display(displayID: UInt32, width: Int, height: Int)
    case window(windowID: UInt32, title: String, owner: String, width: Int, height: Int)
    case application(processID: Int32, bundleIdentifier: String, name: String, displayID: UInt32, width: Int, height: Int)

    var sourceKind: CaptureSourceKind {
        switch self {
        case .display: .display
        case .window: .window
        case .application: .application
        }
    }

    var displayName: String {
        switch self {
        case .display(let displayID, _, _):
            "Display \(displayID)"
        case .window(_, let title, let owner, _, _):
            title.isEmpty ? owner : "\(owner) — \(title)"
        case .application(_, _, let name, _, _, _):
            name
        }
    }

    var outputSize: (width: Int, height: Int) {
        switch self {
        case .display(_, let width, let height),
             .window(_, _, _, let width, let height),
             .application(_, _, _, _, let width, let height):
            // VideoToolbox H.264/HEVC hardware encoders require even dimensions;
            // round down to the nearest even number to avoid AVAssetWriter failures.
            (max(16, width) & ~1, max(16, height) & ~1)
        }
    }
}

nonisolated struct CaptureRegion: Hashable, Sendable {
    var displayID: UInt32
    var sourceRect: CGRect
    var outputWidth: Int
    var outputHeight: Int

    init?(displayID: UInt32,
          selectionInScreen: CGRect,
          screenFrame: CGRect,
          displayPixelWidth: Int,
          displayPixelHeight: Int) {
        guard !selectionInScreen.isNull, !screenFrame.isEmpty else { return nil }
        let clipped = selectionInScreen.intersection(screenFrame)
        guard clipped.width > 0, clipped.height > 0 else { return nil }

        let pixelScaleX = CGFloat(displayPixelWidth) / max(1, screenFrame.width)
        let pixelScaleY = CGFloat(displayPixelHeight) / max(1, screenFrame.height)
        let width = max(16, Int((clipped.width * pixelScaleX).rounded(.down))) & ~1
        let height = max(16, Int((clipped.height * pixelScaleY).rounded(.down))) & ~1
        guard width >= 16, height >= 16 else { return nil }

        self.displayID = displayID
        self.outputWidth = width
        self.outputHeight = height
        self.sourceRect = CGRect(
            x: clipped.minX - screenFrame.minX,
            y: screenFrame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height).integral
    }

    func applies(to target: CaptureTarget) -> Bool {
        guard case .display(let targetDisplayID, _, _) = target else { return false }
        return targetDisplayID == displayID
    }
}

nonisolated struct CaptureDeviceOption: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
}

nonisolated struct CaptureStartRequest: Sendable {
    var target: CaptureTarget?
    var includeSystemAudio: Bool
    var webcamDeviceID: String?
    var microphoneDeviceID: String?
    var rootURL: URL
    var frameRate: Double
    var fragmentInterval: CMTime
    var capabilities: Capabilities
    var captureRegion: CaptureRegion? = nil
    var excludedWindowIDs: Set<CGWindowID> = []
}

nonisolated struct CaptureSessionResult: Sendable, Identifiable {
    let id: UUID
    var directoryURL: URL
    var manifestURL: URL
    var manifest: CaptureManifest
    var wasRecovered: Bool
    /// Set when the manifest's finalize record could not be written (disk full,
    /// volume disappeared, etc.). The UI surfaces this; the manifest remains
    /// unfinalized so the session can still be discovered by crash recovery, but
    /// the warning prevents silent double-landing.
    var _manifestFinalizeFailed: Bool = false
}
