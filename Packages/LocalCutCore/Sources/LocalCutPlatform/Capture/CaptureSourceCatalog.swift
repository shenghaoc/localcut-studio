import Foundation
import AVFoundation
import CoreGraphics
import Darwin
import ScreenCaptureKit

public enum CaptureSourceCatalog {
    @MainActor
    public static func screenOptions() async throws -> [CaptureSourceOption] {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureEngineError.screenRecordingDenied
        }

        let content = try await SCShareableContent.current
        var options: [CaptureSourceOption] = []

        for display in content.displays {
            let width = max(16, display.width)
            let height = max(16, display.height)
            options.append(CaptureSourceOption(
                id: "display-\(display.displayID)",
                title: "Display \(display.displayID)",
                subtitle: "\(width) x \(height)",
                target: .display(displayID: display.displayID, width: width, height: height),
                width: width,
                height: height))
        }

        for window in content.windows where window.isOnScreen {
            let owner = window.owningApplication?.applicationName ?? "Window"
            let title = window.title ?? ""
            let width = max(16, Int(window.frame.width.rounded()))
            let height = max(16, Int(window.frame.height.rounded()))
            options.append(CaptureSourceOption(
                id: "window-\(window.windowID)",
                title: title.isEmpty ? owner : title,
                subtitle: owner,
                target: .window(
                    windowID: window.windowID,
                    title: title,
                    owner: owner,
                    width: width,
                    height: height,
                    frame: window.frame),
                width: width,
                height: height))
        }

        let firstDisplay = content.displays.first
        // Group on-screen windows by owning process ID upfront so the per-app
        // display lookup is O(N + M) instead of a nested O(N × M) scan.
        let windowsByAppID = Dictionary(
            grouping: content.windows.filter { $0.isOnScreen },
            by: { $0.owningApplication?.processID }
        )
        for application in content.applications {
            let appWindows = windowsByAppID[application.processID] ?? []
            let display = content.displays.first(where: { display in
                appWindows.contains(where: { display.frame.intersects($0.frame) })
            }) ?? firstDisplay
            guard let display else { continue }
            let width = max(16, display.width)
            let height = max(16, display.height)
            options.append(CaptureSourceOption(
                id: "app-\(application.processID)",
                title: application.applicationName,
                subtitle: application.bundleIdentifier,
                target: .application(
                    processID: application.processID,
                    bundleIdentifier: application.bundleIdentifier,
                    name: application.applicationName,
                    displayID: display.displayID,
                    width: width,
                    height: height),
                width: width,
                height: height))
        }

        return options
    }

    @MainActor
    public static func webcamOptions() -> [CaptureDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified)
        return discovery.devices.map { CaptureDeviceOption(id: $0.uniqueID, title: $0.localizedName) }
    }

    @MainActor
    public static func microphoneOptions() -> [CaptureDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified)
        return discovery.devices.map { CaptureDeviceOption(id: $0.uniqueID, title: $0.localizedName) }
    }

    /// True when the host supports system audio capture via ScreenCaptureKit.
    /// System audio requires macOS 13+ and a chip with hardware audio routing
    /// (Apple Silicon). Intel Macs running macOS 13+ may report the capability
    /// but cannot reliably deliver system audio through SCStream.
    public static nonisolated var isSystemAudioAvailable: Bool {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion < 13 { return false }
        let isAppleSilicon = {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
            return value == 1
        }()
        return isAppleSilicon
    }
}
