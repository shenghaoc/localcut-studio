import Foundation
import LocalCutCore

extension EditorModel {
    func startWhipPublish(config: PublishConfig) async {
        guard let endpointURL = URL(string: publishSettings.endpointURL) else { return }
        let token = publishSettings.tokenForCurrentEndpoint()
        let videoTap = VideoPublishTap()
        let audioBridge = AudioPublishBridge()
        do {
            let session = WhipSession(client: WhipClientImpl(), budget: encoderBudget, config: config)
            whipSession = session
            try await session.start(endpointURL: endpointURL, authToken: token, config: config)
        } catch {
            print("[WHIP] Publish failed: \(error.localizedDescription)")
        }
    }

    func stopWhipPublish() async {
        guard let session = whipSession else { return }
        await session.stop()
        whipSession = nil
    }
}
