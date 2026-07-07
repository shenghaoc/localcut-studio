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
    var isProgramOutputAvailable: Bool = false

    var canStart: Bool {
        !isStarting && !isStopping
        && canAttemptStartFromCurrentState
        && !endpointURL.isEmpty
        && URL(string: endpointURL) != nil
        && (!endpointRequiresToken || !bearerToken.isEmpty)
        && isWebRTCAvailable
        && isBudgetAvailable
        && isProgramOutputAvailable
    }

    var endpointRequiresToken: Bool { endpointType.requiresToken }
    var availableCodecs: [PublishCodec] {
        PublishCodec.allCases.filter { codec in
            switch codec {
            case .h264Baseline:
                true
            case .av1:
                PublishCodecProber.isAV1Available(for: endpointType)
            }
        }
    }
    private var canAttemptStartFromCurrentState: Bool {
        switch publishState {
        case .idle, .failed, .ended:
            true
        case .connecting, .live, .reconnecting:
            false
        }
    }

    /// Task that observes the WhipSession state stream.
    private var stateObservationTask: Task<Void, Never>?
    private var statsPollingTask: Task<Void, Never>?

    func loadSettings(from model: EditorModel) {
        endpointType = model.publishSettings.endpointType
        endpointURL = model.publishSettings.endpointURL.isEmpty
            ? endpointType.defaultEndpointURL
            : model.publishSettings.endpointURL
        rememberToken = model.publishSettings.rememberToken
        bearerToken = endpointRequiresToken
            ? (model.publishSettings.tokenForCurrentEndpoint() ?? "")
            : ""
        applyProfile(PublishEndpointDefaults.default(for: endpointType))
        normalizeCodecForEndpoint()
    }

    func endpointTypeDidChange(from oldType: PublishEndpointType, model: EditorModel) {
        if endpointURL.isEmpty || endpointURL == oldType.defaultEndpointURL {
            endpointURL = endpointType.defaultEndpointURL
        }
        applyProfile(PublishEndpointDefaults.default(for: endpointType))
        normalizeCodecForEndpoint()
        if endpointRequiresToken {
            model.publishSettings.endpointType = endpointType
            model.publishSettings.endpointURL = endpointURL
            rememberToken = model.publishSettings.rememberToken
            bearerToken = model.publishSettings.tokenForCurrentEndpoint() ?? ""
        } else {
            bearerToken = ""
            rememberToken = false
        }
    }

    func startPublish(model: EditorModel) {
        guard canStart else { return }
        normalizeCodecForEndpoint()
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

        if endpointRequiresToken {
            model.publishSettings.bearerToken = bearerToken.isEmpty ? nil : bearerToken
            model.publishSettings.rememberToken = rememberToken
        } else {
            model.publishSettings.bearerToken = nil
            model.publishSettings.rememberToken = false
        }

        Task { [weak self] in
            defer { self?.isStarting = false }
            do {
                try await model.startWhipPublish(config: config)
                // Observe session state changes instead of assuming Live.
                self?.observeSessionState(model: model)
                self?.startStatsPolling(model: model)
            } catch {
                self?.publishState = .failed
                self?.statusMessage = error.localizedDescription
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
        }
    }

    private func startStatsPolling(model: EditorModel) {
        statsPollingTask?.cancel()
        statsPollingTask = Task { [weak self, weak model] in
            guard let self, let model else { return }
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
        statsPollingTask?.cancel()
        isStopping = true
        publishState = .ended
        statusMessage = "Stopping..."
        Task { [weak self] in
            defer { self?.isStopping = false }
            await model.stopWhipPublish()
            self?.publishState = .idle
            self?.statusMessage = "Publish ended."
            self?.stats = nil
        }
    }

    func refreshCapability(model: EditorModel) {
        #if LOCALCUT_ENABLE_WEBRTC
        isWebRTCAvailable = true
        #else
        isWebRTCAvailable = false
        #endif
        isProgramOutputAvailable = model.programSession != nil
        Task { [weak self, weak model] in
            guard let self, let model else { return }
            isBudgetAvailable = await model.encoderBudget.availableCount > 0
        }
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

    private func applyProfile(_ profile: PublishProfile) {
        selectedCodec = profile.codec
        videoBitrate = profile.videoBitrate / 1_000
        audioBitrate = profile.audioBitrate / 1_000
        keyframeInterval = profile.keyframeInterval
    }

    private func normalizeCodecForEndpoint() {
        if !availableCodecs.contains(selectedCodec) {
            selectedCodec = .h264Baseline
        }
    }
}
