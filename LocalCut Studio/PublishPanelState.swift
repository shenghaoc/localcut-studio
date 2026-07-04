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

    /// Task that observes the WhipSession state stream.
    private var stateObservationTask: Task<Void, Never>?

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

        // Always store the typed token in session settings so
        // startWhipPublish can read it. Only persist to Keychain
        // when the user explicitly opts in.
        if !bearerToken.isEmpty {
            model.publishSettings.bearerToken = bearerToken
        }
        if rememberToken && !bearerToken.isEmpty {
            model.publishSettings.saveTokenToKeychain()
        }

        Task {
            defer { isStarting = false }
            do {
                try await model.startWhipPublish(config: config)
                // Observe session state changes instead of assuming Live.
                observeSessionState(model: model)
            } catch {
                publishState = .failed
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Subscribes to the WhipSession state stream and updates the UI.
    private func observeSessionState(model: EditorModel) {
        stateObservationTask?.cancel()
        stateObservationTask = Task { [weak self, weak model] in
            guard let self, let model, let session = model.whipSession else { return }
            for await state in await session.stateStream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    switch state {
                    case .idle:
                        self.publishState = .idle
                        self.statusMessage = ""
                    case .connecting:
                        self.publishState = .connecting
                        self.statusMessage = "Connecting..."
                    case .live:
                        self.publishState = .live
                        self.statusMessage = "Live — streaming to \(self.endpointType.displayName)."
                    case .reconnecting:
                        self.publishState = .reconnecting
                        self.statusMessage = "Reconnecting..."
                    case .failed(let message):
                        self.publishState = .failed
                        self.statusMessage = message
                    case .ended:
                        self.publishState = .idle
                        self.statusMessage = "Publish ended."
                        self.stats = nil
                    }
                }
            }
            // Also poll stats while live.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let session = model.whipSession else { break }
                let sessionStats = await session.stats
                await MainActor.run {
                    self.stats = PublishStatsDisplay(
                        bytesSent: sessionStats.bytesSent,
                        framesSent: sessionStats.framesSent,
                        bitrate: sessionStats.bitrate,
                        rtt: sessionStats.rtt
                    )
                }
            }
        }
    }

    func stopPublish(model: EditorModel) {
        guard publishState == .live || publishState == .reconnecting || publishState == .connecting else { return }
        stateObservationTask?.cancel()
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
