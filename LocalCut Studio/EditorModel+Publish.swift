import Foundation
import AVFAudio
import LocalCutCore

enum WhipPublishStartError: LocalizedError {
    case invalidEndpoint
    case programOutputUnavailable
    case alreadyPublishing
    case audioUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Enter a valid WHIP endpoint URL."
        case .programOutputUnavailable:
            "Start Program Mode before publishing. WHIP streams the live program output."
        case .alreadyPublishing:
            "A WHIP publish session is already running."
        case .audioUnavailable(let message):
            "Could not start the live audio bus for publishing: \(message)"
        }
    }
}

extension EditorModel {
    func startWhipPublish(config: PublishConfig) async throws {
        guard whipSession == nil else {
            throw WhipPublishStartError.alreadyPublishing
        }
        guard let endpointURL = URL(string: publishSettings.endpointURL) else {
            throw WhipPublishStartError.invalidEndpoint
        }
        guard let programSession else {
            throw WhipPublishStartError.programOutputUnavailable
        }
        let token = publishSettings.tokenForCurrentEndpoint()
        audioBus.prepareLive()
        guard audioBus.isLiveRunning else {
            throw WhipPublishStartError.audioUnavailable(
                audioBus.lastStartError ?? "The audio device is unavailable.")
        }

        let videoTap = VideoPublishTap()
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
