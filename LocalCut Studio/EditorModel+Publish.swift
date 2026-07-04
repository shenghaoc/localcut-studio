import Foundation
import AVFAudio
import LocalCutCore

#if canImport(WebRTC)
import WebRTC
#endif

enum WhipPublishStartError: LocalizedError {
    case invalidEndpoint
    case programOutputUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Enter a valid WHIP endpoint URL."
        case .programOutputUnavailable:
            "Start Program Mode before publishing. WHIP streams the live program output."
        }
    }
}

extension EditorModel {
    func startWhipPublish(config: PublishConfig) async throws {
        guard let endpointURL = URL(string: publishSettings.endpointURL) else {
            throw WhipPublishStartError.invalidEndpoint
        }
        guard let programSession else {
            throw WhipPublishStartError.programOutputUnavailable
        }
        let token = publishSettings.tokenForCurrentEndpoint()

        #if canImport(WebRTC)
        let factory = RTCPeerConnectionFactory()
        let videoTap = VideoPublishTap(factory: factory)
        #else
        let videoTap = VideoPublishTap()
        #endif
        let audioBridge = AudioPublishBridge()
        await audioBridge.start(
            sampleRate: AudioMasterBus.canonicalFormat.sampleRate,
            channels: Int(AudioMasterBus.canonicalFormat.channelCount))

        let session = WhipSession(
            client: WhipClientImpl(),
            budget: encoderBudget,
            config: config
        )
        whipSession = session

        // Store taps so they stay alive for the session lifetime.
        publishVideoTap = videoTap
        publishAudioBridge = audioBridge
        let sinkID = await programSession.addFrameSink { [weak videoTap] buffer in
            videoTap?.capturePixelBuffer(buffer)
        }
        publishProgramFrameSinkID = sinkID
        audioBus.setPublishSampleSink { [weak audioBridge] samples, sampleRate, channels in
            audioBridge?.pushSamples(samples, sampleRate: sampleRate, channels: channels)
        }

        do {
            try await session.start(
                endpointURL: endpointURL,
                authToken: token,
                config: config,
                videoTap: videoTap,
                audioBridge: audioBridge
            )
        } catch {
            await programSession.removeFrameSink(id: sinkID)
            publishProgramFrameSinkID = nil
            audioBus.setPublishSampleSink(nil)
            await audioBridge.stop()
            publishVideoTap = nil
            publishAudioBridge = nil
            whipSession = nil
            throw error
        }
    }

    func stopWhipPublish() async {
        guard let session = whipSession else { return }
        await session.stop()
        if let sinkID = publishProgramFrameSinkID {
            await programSession?.removeFrameSink(id: sinkID)
        }
        audioBus.setPublishSampleSink(nil)
        whipSession = nil
        publishVideoTap = nil
        publishAudioBridge = nil
        publishProgramFrameSinkID = nil
    }
}
