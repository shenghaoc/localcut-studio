import Foundation
import os
import LocalCutCore

#if canImport(WebRTC)
import WebRTC
#endif

// MARK: - Publish state

nonisolated enum PublishState: Sendable, Equatable {
    case idle, connecting, live, reconnecting, failed(String), ended
}

// MARK: - Publish stats

struct PublishStats: Sendable, Equatable {
    var bytesSent: Int64 = 0
    var framesSent: Int64 = 0
    var bitrate: Double = 0
    var rtt: TimeInterval = 0
}

// MARK: - Publish config

struct PublishConfig: Sendable {
    var videoCodec: String = "H264"
    var videoBitrate: UInt = 2_500_000
    var keyframeInterval: Double = 2.0
    var audioStereo: Bool = true
    var audioBitrate: UInt = 128_000
}

// MARK: - WhipSession actor

actor WhipSession {
    private(set) var state: PublishState = .idle {
        didSet {
            guard state != oldValue else { return }
            stateContinuation?.yield(state)
            if state == .ended { stateContinuation?.finish() }
        }
    }
    private(set) var stats = PublishStats()

    private var resourceUrl: URL?
    private var etag: String?
    private let client: any WhipClient
    private let budget: EncoderBudget
    private var config: PublishConfig
    private let reconnectController: ReconnectController
    private var authToken: String?
    private var encoderLease: EncoderLease?
    private var currentEndpointConfig: (endpoint: URL, authToken: String?)?
    private var iceServerUrls: [ICEServerInfo] = []
    private var videoTap: VideoPublishTap?
    private var audioBridge: AudioPublishBridge?

    #if canImport(WebRTC)
    private let factory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    private var peerConnectionDelegate: WhipPeerConnectionDelegate?
    private var videoTransceiver: RTCRtpTransceiver?
    private var audioTransceiver: RTCRtpTransceiver?
    #endif

    private var stateContinuation: AsyncStream<PublishState>.Continuation?
    nonisolated(unsafe) private var _cachedStateStream: AsyncStream<PublishState>?
    private var statsTask: Task<Void, Never>?

    init(client: some WhipClient, budget: EncoderBudget, config: PublishConfig = PublishConfig(), reconnectController: ReconnectController = ReconnectController()) {
        self.client = client
        self.budget = budget
        self.config = config
        self.reconnectController = reconnectController
    }

    var stateStream: AsyncStream<PublishState> {
        if let existing = _cachedStateStream { return existing }
        let (stream, continuation) = AsyncStream<PublishState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stateContinuation = continuation
        continuation.yield(state)
        _cachedStateStream = stream
        return stream
    }

    func start(endpointURL: URL, authToken: String? = nil, config: PublishConfig? = nil, videoTap: VideoPublishTap? = nil, audioBridge: AudioPublishBridge? = nil) async throws {
        guard canStartFromCurrentState else { return }
        state = .connecting
        self.authToken = authToken
        if let config { self.config = config }
        self.videoTap = videoTap
        self.audioBridge = audioBridge
        await audioBridge?.start(
            sampleRate: 48_000,
            channels: self.config.audioStereo ? 2 : 1)

        do {
            encoderLease = try await budget.acquire(.whipPublish)
        } catch let error as EncoderBudgetError {
            state = .failed(error.localizedDescription)
            throw error
        }

        reconnectController.reset()
        do {
            try await connect(endpointURL: endpointURL)
        } catch {
            // Tear down any partially-created server-side resource and
            // WebRTC resources before releasing the encoder lease.
            if let resourceUrl {
                await client.teardown(resourceUrl: resourceUrl, authToken: authToken)
            }
            videoTap?.close()
            await audioBridge?.stop()
            self.audioBridge = nil
            closeWebRTCResources()
            releaseEncoderBudget()
            resourceUrl = nil
            etag = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        guard state != .ended else { return }
        statsTask?.cancel()
        statsTask = nil
        if let url = resourceUrl {
            await client.teardown(resourceUrl: url, authToken: authToken)
        }
        videoTap?.close()
        await audioBridge?.stop()
        audioBridge = nil
        closeWebRTCResources()
        releaseEncoderBudget()
        resourceUrl = nil
        etag = nil
        state = .ended
    }

    func handleDisconnect() async {
        guard state == .live || state == .reconnecting else { return }
        statsTask?.cancel()
        statsTask = nil
        guard reconnectController.canAttemptReconnect else {
            await failAndCleanup("Reconnect attempts exhausted.")
            return
        }
        state = .reconnecting

        // Wait for the 3-second grace period on first disconnect to
        // allow transient WebRTC disconnects to recover.
        reconnectController.markDisconnected()
        try? await reconnectController.waitForGracePeriod()
        guard !Task.isCancelled else { return }

        // Advance attempt count BEFORE reading backoff so the first
        // reconnect uses the correct backoff ladder entry.
        reconnectController.advanceAttempt()

        if reconnectController.shouldTryIceRestart {
            let backoff = reconnectController.backoffDuration
            if backoff > 0 { try? await Task.sleep(for: .seconds(backoff)) }
            guard !Task.isCancelled else { return }
            await attemptIceRestart()
        } else {
            let backoff = reconnectController.backoffDuration
            if backoff > 0 { try? await Task.sleep(for: .seconds(backoff)) }
            guard !Task.isCancelled else { return }
            await attemptFullReconnect()
        }
    }

    // MARK: - Private

    private var canStartFromCurrentState: Bool {
        switch state {
        case .idle, .ended, .failed:
            true
        case .connecting, .live, .reconnecting:
            false
        }
    }

    private func connect(endpointURL: URL) async throws {
        currentEndpointConfig = (endpoint: endpointURL, authToken: authToken)
        #if canImport(WebRTC)
        try configurePeerConnection()
        let offer = try await createOffer()
        let response = try await client.publish(endpoint: endpointURL, offerSdp: offer, authToken: authToken)
        resourceUrl = response.resourceUrl
        etag = response.etag
        reconnectController.updateETag(response.etag)
        iceServerUrls = response.iceServers
        try await applyAnswerSdp(response.answerSdp)
        #else
        try await Task.sleep(for: .milliseconds(100))
        #endif
        state = .live
        startStatsPolling()
    }

    private func attemptIceRestart() async {
        guard let url = resourceUrl, let etag = etag else {
            await attemptFullReconnect()
            return
        }
        #if canImport(WebRTC)
        do {
            guard let pc = peerConnection else { await attemptFullReconnect(); return }
            // Request an actual ICE restart by setting the iceRestart
            // option, which generates new ufrag/pwd in the SDP.
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: ["IceRestart": "true"],
                optionalConstraints: nil
            )
            let offer = try await pc.offer(for: constraints)
            try await pc.setLocalDescription(offer)
            let response = try await client.patchIceRestart(resourceUrl: url, offerSdp: offer.sdp, etag: etag, authToken: authToken)
            self.etag = response.newEtag
            reconnectController.updateETag(response.newEtag)
            let answer = RTCSessionDescription(type: .answer, sdp: response.answerSdp)
            try await pc.setRemoteDescription(answer)
            state = .live
            startStatsPolling()
        } catch {
            await attemptFullReconnect()
        }
        #else
        state = .live
        startStatsPolling()
        #endif
    }

    private func attemptFullReconnect() async {
        guard let config = currentEndpointConfig else {
            await failAndCleanup("Cannot reconnect: endpoint not configured.")
            return
        }
        // DELETE the old server-side resource before opening a new session.
        if let oldUrl = resourceUrl {
            await client.teardown(resourceUrl: oldUrl, authToken: authToken)
        }
        closeWebRTCResources()
        if encoderLease == nil {
            do { encoderLease = try await budget.acquire(.whipPublish) }
            catch { await failAndCleanup("Budget re-acquire failed."); return }
        }
        resourceUrl = nil
        etag = nil
        reconnectController.resetETag()
        do { try await connect(endpointURL: config.endpoint) }
        catch { await failAndCleanup(error.localizedDescription) }
    }

    private func failAndCleanup(_ message: String) async {
        videoTap?.close()
        await audioBridge?.stop()
        audioBridge = nil
        closeWebRTCResources()
        releaseEncoderBudget()
        resourceUrl = nil
        etag = nil
        currentEndpointConfig = nil
        state = .failed(message)
    }

    private func releaseEncoderBudget() {
        if let lease = encoderLease { lease.relinquish(); encoderLease = nil }
    }

    private func closeWebRTCResources() {
        statsTask?.cancel()
        statsTask = nil
        videoTap?.close()
        videoTap = nil
        #if canImport(WebRTC)
        videoTransceiver = nil
        audioTransceiver = nil
        peerConnection?.close()
        peerConnection = nil
        peerConnectionDelegate = nil
        #endif
    }

    #if canImport(WebRTC)
    private func configurePeerConnection() throws {
        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = iceServerUrls.map { info in
            if let username = info.username, let credential = info.credential {
                return RTCIceServer(urlStrings: [info.url.absoluteString], username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: [info.url.absoluteString])
        }
        rtcConfig.sdpSemantics = .unifiedPlan
        rtcConfig.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        let delegate = WhipPeerConnectionDelegate(session: self)
        guard let pc = factory.peerConnection(with: rtcConfig, constraints: constraints, delegate: delegate) else {
            throw WhipError.transport(statusCode: 0, message: "Failed to create RTCPeerConnection.")
        }
        peerConnection = pc
        peerConnectionDelegate = delegate
        let sendOnly = RTCRtpTransceiverInit()
        sendOnly.direction = .sendOnly
        if let videoTap {
            let videoTrack = factory.videoTrack(
                with: videoTap.videoSource,
                trackId: "localcut-program-video")
            videoTransceiver = pc.addTransceiver(with: videoTrack, init: sendOnly)
        } else {
            videoTransceiver = pc.addTransceiver(of: .video)
            videoTransceiver?.setDirection(.sendOnly, error: nil)
        }
        let audioSource = factory.audioSource(with: nil)
        let audioTrack = factory.audioTrack(
            with: audioSource,
            trackId: "localcut-master-audio")
        audioTransceiver = pc.addTransceiver(with: audioTrack, init: sendOnly)

        // Apply codec preferences from the publish config.
        if config.videoCodec == "H264" {
            let codecs = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
            if !codecs.isEmpty {
                let h264 = codecs.filter { $0.name == "H264" }
                if !h264.isEmpty {
                    videoTransceiver?.setCodecPreferences(h264)
                }
            }
        }

        // Apply bitrate limits to the video sender.
        let params = videoTransceiver?.sender.parameters ?? RTCRtpParameters()
        if let encoding = params.encodings.first {
            encoding.maxBitrateBps = NSNumber(value: config.videoBitrate)
            params.encodings = [encoding]
        }
        videoTransceiver?.sender.parameters = params
    }

    private func createOffer() async throws -> String {
        guard let pc = peerConnection else { throw WhipError.transport(statusCode: 0, message: "No peer connection.") }
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"], optionalConstraints: nil)
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        return offer.sdp
    }

    private func applyAnswerSdp(_ sdp: String) async throws {
        guard let pc = peerConnection else { throw WhipError.transport(statusCode: 0, message: "No peer connection.") }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await pc.setRemoteDescription(answer)
    }
    #endif

    private func startStatsPolling() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.collectStats()
            }
        }
    }

    private func collectStats() async {
        #if canImport(WebRTC)
        guard let pc = peerConnection else { return }
        let report = await pc.statistics()
        processStatsReport(report)
        #endif
    }

    #if canImport(WebRTC)
    private func processStatsReport(_ report: RTCStatisticsReport) {
        var newStats = PublishStats()
        for (_, stat) in report.statistics {
            if stat.type == "outbound-rtp", stat.values["kind"] as? String == "video" {
                newStats.bytesSent = stat.values["bytesSent"] as? Int64 ?? 0
                newStats.framesSent = stat.values["framesSent"] as? Int64 ?? 0
            }
            if stat.type == "candidate-pair", let nominated = stat.values["nominated"] as? Bool, nominated {
                newStats.rtt = stat.values["currentRoundTripTime"] as? TimeInterval ?? 0
            }
        }
        let prevBytes = stats.bytesSent
        if newStats.bytesSent > prevBytes { newStats.bitrate = Double(newStats.bytesSent - prevBytes) * 8.0 / 1000.0 }
        stats = newStats
    }
    #endif
}

// WhipError.transport case needed for WebRTC path
extension WhipError {
    static func transport(statusCode: Int, message: String) -> WhipError {
        .httpStatus(statusCode, message.data(using: .utf8))
    }
}

// MARK: - RTCPeerConnectionDelegate

#if canImport(WebRTC)
private nonisolated final class WhipPeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate {
    private weak var session: WhipSession?

    init(session: WhipSession) {
        self.session = session
        super.init()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .disconnected:
            Task { [weak session] in await session?.handleDisconnect() }
        case .failed:
            Task { [weak session] in await session?.handleDisconnect() }
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeStandardizedIceConnectionState newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange connectionState: RTCPeerConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}
}
#endif
