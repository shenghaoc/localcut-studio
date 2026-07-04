import Foundation
import LocalCutCore

#if canImport(WebRTC)
import WebRTC
#endif

extension EditorModel {
    func startWhipPublish(config: PublishConfig) async {
        guard let endpointURL = URL(string: publishSettings.endpointURL) else { return }
        let token = publishSettings.tokenForCurrentEndpoint()

        #if canImport(WebRTC)
        let factory = RTCPeerConnectionFactory()
        let videoTap = VideoPublishTap(factory: factory)
        #else
        let videoTap = VideoPublishTap()
        #endif
        let audioBridge = AudioPublishBridge()

        let session = WhipSession(
            client: WhipClientImpl(),
            budget: encoderBudget,
            config: config
        )
        whipSession = session

        // Store taps so they stay alive for the session lifetime.
        publishVideoTap = videoTap
        publishAudioBridge = audioBridge

        do {
            try await session.start(
                endpointURL: endpointURL,
                authToken: token,
                config: config,
                videoTap: videoTap,
                audioBridge: audioBridge
            )
        } catch {
            publishVideoTap = nil
            publishAudioBridge = nil
            print("[WHIP] Publish failed: \(error.localizedDescription)")
        }
    }

    func stopWhipPublish() async {
        guard let session = whipSession else { return }
        await session.stop()
        whipSession = nil
        publishVideoTap = nil
        publishAudioBridge = nil
    }
}
