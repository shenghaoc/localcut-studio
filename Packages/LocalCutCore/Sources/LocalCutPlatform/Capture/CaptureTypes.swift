import Foundation
import CoreGraphics
import CoreMedia
import LocalCutCore
import LocalCutDomain

public nonisolated enum CaptureEngineError: LocalizedError, Equatable {
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

    public var errorDescription: String? {
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

public nonisolated struct CaptureSourceOption: Identifiable, Hashable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var target: CaptureTarget
    public var width: Int
    public var height: Int
}

public nonisolated enum CaptureTarget: Hashable, Sendable {
    case display(displayID: UInt32, width: Int, height: Int)
    case window(windowID: UInt32, title: String, owner: String, width: Int, height: Int, frame: CGRect)
    case application(processID: Int32, bundleIdentifier: String, name: String, displayID: UInt32, width: Int, height: Int)

    public var sourceKind: CaptureSourceKind {
        switch self {
        case .display: .display
        case .window: .window
        case .application: .application
        }
    }

    public var displayName: String {
        switch self {
        case .display(let displayID, _, _):
            "Display \(displayID)"
        case .window(_, let title, let owner, _, _, _):
            title.isEmpty ? owner : "\(owner) — \(title)"
        case .application(_, _, let name, _, _, _):
            name
        }
    }

    public var outputSize: (width: Int, height: Int) {
        switch self {
        case .display(_, let width, let height),
             .window(_, _, _, let width, let height, _),
             .application(_, _, _, _, let width, let height):
            // VideoToolbox H.264/HEVC hardware encoders require even dimensions;
            // round down to the nearest even number to avoid AVAssetWriter failures.
            (max(16, width) & ~1, max(16, height) & ~1)
        }
    }
}

public nonisolated struct CaptureRegion: Hashable, Sendable {
    public var displayID: UInt32
    public var sourceRect: CGRect
    public var outputWidth: Int
    public var outputHeight: Int

    public init?(displayID: UInt32,
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

    public func applies(to target: CaptureTarget) -> Bool {
        guard case .display(let targetDisplayID, _, _) = target else { return false }
        return targetDisplayID == displayID
    }
}

public nonisolated struct CaptureDeviceOption: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
}

public nonisolated struct CaptureStartRequest: Sendable {
    public var target: CaptureTarget?
    public var includeSystemAudio: Bool
    public var webcamDeviceID: String?
    public var microphoneDeviceID: String?
    public var rootURL: URL
    public var frameRate: Double
    public var fragmentInterval: CMTime
    public var capabilities: Capabilities
    public var captureRegion: CaptureRegion?
    public var excludedWindowIDs: Set<CGWindowID>
    /// Voice cleanup settings store for mic recording path (Phase 36/46).
    /// When non-nil, mic audio is processed through VoiceCleanupDSP before encoding.
    public var voiceCleanupSettings: LiveVoiceCleanupSettingsStore?

    public init(
        target: CaptureTarget?,
        includeSystemAudio: Bool,
        webcamDeviceID: String?,
        microphoneDeviceID: String?,
        rootURL: URL,
        frameRate: Double,
        fragmentInterval: CMTime,
        capabilities: Capabilities,
        captureRegion: CaptureRegion? = nil,
        excludedWindowIDs: Set<CGWindowID> = [],
        voiceCleanupSettings: LiveVoiceCleanupSettingsStore? = nil
    ) {
        self.target = target
        self.includeSystemAudio = includeSystemAudio
        self.webcamDeviceID = webcamDeviceID
        self.microphoneDeviceID = microphoneDeviceID
        self.rootURL = rootURL
        self.frameRate = frameRate
        self.fragmentInterval = fragmentInterval
        self.capabilities = capabilities
        self.captureRegion = captureRegion
        self.excludedWindowIDs = excludedWindowIDs
        self.voiceCleanupSettings = voiceCleanupSettings
    }
}

public nonisolated struct CaptureSessionResult: Sendable, Identifiable {
    public let id: UUID
    public var directoryURL: URL
    public var manifestURL: URL
    public var manifest: CaptureManifest
    public var wasRecovered: Bool
    /// Non-nil when the manifest's finalize record could not be written (disk
    /// full, volume disappeared, prior critical manifest write failed, etc.).
    /// The UI surfaces this; the manifest remains unfinalized so crash recovery
    /// can still discover the session.
    public var manifestFinalizationError: String?

    public var manifestFinalizeFailed: Bool {
        manifestFinalizationError != nil
    }
}
