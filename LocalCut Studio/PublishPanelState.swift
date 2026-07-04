import SwiftUI
import LocalCutCore

enum PublishStateDisplay: String {
    case idle, connecting, live, reconnecting, failed, ended
}

struct PublishStatsDisplay {
    var bytesSent: Int64 = 0
    var framesSent: Int64 = 0
    var bitrate: Double = 0
    var rtt: TimeInterval = 0
}

@Observable
@MainActor
final class PublishPanelState {
    var endpointURL: String = ""
    var endpointType: PublishEndpointType = .custom
    var bearerToken: String = ""
    var rememberToken: Bool = false

    var selectedCodec: PublishCodec = .h264Baseline
    var videoBitrate: Int = 6_000
    var audioBitrate: Int = 128
    var keyframeInterval: Int = 2

    var publishState: PublishStateDisplay = .idle
    var statusMessage: String = ""
    var stats: PublishStatsDisplay?
    var isStarting: Bool = false
    var isStopping: Bool = false
    var isWebRTCAvailable: Bool = false
    var isBudgetAvailable: Bool = true

    var canStart: Bool {
        !isStarting && !isStopping
        && publishState == .idle
        && !endpointURL.isEmpty
        && URL(string: endpointURL) != nil
        && (!endpointRequiresToken || !bearerToken.isEmpty)
        && isWebRTCAvailable
        && isBudgetAvailable
    }

    var endpointRequiresToken: Bool { endpointType.requiresToken }

    func startPublish(model: EditorModel) {
        guard canStart else { return }
        isStarting = true
        publishState = .connecting
        statusMessage = "Connecting to \(endpointType.displayName)..."

        let config = PublishConfig(
            videoCodec: selectedCodec == .h264Baseline ? "H264" : "AV1",
            videoBitrate: UInt(videoBitrate * 1_000),
            keyframeInterval: Double(keyframeInterval),
            audioStereo: true,
            audioBitrate: UInt(audioBitrate * 1_000)
        )

        model.publishSettings.endpointURL = endpointURL
        model.publishSettings.endpointType = endpointType

        if rememberToken && !bearerToken.isEmpty {
            model.publishSettings.bearerToken = bearerToken
            model.publishSettings.saveTokenToKeychain()
        }

        Task {
            defer { isStarting = false }
            do {
                try await model.startWhipPublish(config: config)
                publishState = .live
                statusMessage = "Live — streaming to \(endpointType.displayName)."
            } catch {
                publishState = .failed
                statusMessage = error.localizedDescription
            }
        }
    }

    func stopPublish(model: EditorModel) {
        guard publishState == .live || publishState == .reconnecting else { return }
        isStopping = true
        publishState = .ended
        statusMessage = "Stopping..."
        Task {
            defer { isStopping = false }
            await model.stopWhipPublish()
            publishState = .idle
            statusMessage = "Publish ended."
            stats = nil
        }
    }

    func refreshCapability(budget: EncoderBudget) {
        #if canImport(WebRTC)
        isWebRTCAvailable = true
        #else
        isWebRTCAvailable = false
        #endif
        Task { isBudgetAvailable = await budget.availableCount > 0 }
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }

    static func formattedBitrate(_ kbps: Double) -> String {
        kbps >= 1_000 ? String(format: "%.1f Mbps", kbps / 1_000) : String(format: "%.0f kbps", kbps)
    }

    static func formattedRTT(_ rtt: TimeInterval) -> String {
        String(format: "%.0f ms", rtt * 1_000)
    }
}
