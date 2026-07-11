import Foundation
import Testing
import LocalCutCore
import LocalCutDomain
@testable import LocalCut_Studio

/// MediaMTX WHIP integration test.
///
/// Verifies that LocalCut can publish to a real WHIP ingest endpoint
/// (MediaMTX started by the integration script), assert ingest, and tear down cleanly.
///
/// This test requires MediaMTX running on localhost:8889. Normal local test
/// runs leave the suite disabled; the integration script creates a short-lived
/// marker after starting MediaMTX and removes it during cleanup.
private enum MediaMTXIntegrationGate {
    nonisolated static let markerURL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/mediamtx/integration-enabled")

    nonisolated static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }
}

private nonisolated struct RecordedPublishResult: Sendable {
    let resourceURL: URL
    let answerSDP: String
}

@MainActor
private final class RecordingWhipClient: WhipClient {
    private let base: WhipClientImpl
    private(set) var lastPublish: RecordedPublishResult?

    init() {
        base = WhipClientImpl(session: .shared)
    }

    func publish(
        endpoint: URL,
        offerSdp: String,
        authToken: String?
    ) async throws -> (resourceUrl: URL, etag: String, iceServers: [ICEServerInfo], answerSdp: String) {
        let result = try await base.publish(
            endpoint: endpoint,
            offerSdp: offerSdp,
            authToken: authToken)
        lastPublish = RecordedPublishResult(
            resourceURL: result.resourceUrl,
            answerSDP: result.answerSdp)
        return result
    }

    func patchIceRestart(
        resourceUrl: URL,
        sdpFragment: String,
        etag: String,
        authToken: String?
    ) async throws -> (answerSdp: String, newEtag: String) {
        try await base.patchIceRestart(
            resourceUrl: resourceUrl,
            sdpFragment: sdpFragment,
            etag: etag,
            authToken: authToken)
    }

    func teardown(resourceUrl: URL, authToken: String?) async {
        await base.teardown(resourceUrl: resourceUrl, authToken: authToken)
    }
}

@Suite(
    "MediaMTX WHIP integration",
    .serialized,
    .enabled(if: MediaMTXIntegrationGate.isEnabled)
)
struct WhipMediaMTXIntegrationTests {

    private static let endpointURL = "http://localhost:8889/stream/whip"
    private static let apiURL = "http://localhost:9997"

    /// Returns true if MediaMTX is reachable on localhost.
    private static func isMediaMTXAvailable() async -> Bool {
        guard let url = URL(string: "\(apiURL)/v3/config/global/get") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Issue.record("MediaMTX readiness endpoint returned an unexpected response: \(response)")
                return false
            }
            return true
        } catch {
            Issue.record("MediaMTX readiness request failed: \(error)")
            return false
        }
    }

    @Test("WHIP POST returns SDP answer from MediaMTX")
    func whipPostReturnsAnswer() async throws {
        guard await Self.isMediaMTXAvailable() else {
            return
        }

        let client = RecordingWhipClient()
        let session = WhipSession(client: client, budget: EncoderBudget(maxConcurrent: 4))

        do {
            try await session.start(
                endpointURL: URL(string: Self.endpointURL)!,
                config: PublishConfig(
                    videoCodec: "VP8",
                    videoBitrate: 500_000,
                    keyframeInterval: 2.0,
                    audioStereo: true,
                    audioBitrate: 64_000)
            )
            let result = try #require(client.lastPublish)

            // Verify we got a valid response
            #expect(!result.answerSDP.isEmpty, "Answer SDP should not be empty")
            #expect(result.resourceURL.absoluteString.contains("stream"), "Resource URL should reference the stream")

            // Teardown sends DELETE through the recording client.
            await session.stop()

            // Verify the path is no longer active
            try await Task.sleep(for: .milliseconds(500))
            let paths = try await fetchActivePaths()
            #expect(!paths.contains("stream"), "Path 'stream' should be inactive after teardown")
        } catch {
            Issue.record("WHIP publish failed: \(error)")
            await session.stop()
        }
    }

    @Test("Publish state reaches live and transitions to ended on stop")
    func publishStateTransitions() async throws {
        guard await Self.isMediaMTXAvailable() else {
            return
        }

        let budget = EncoderBudget(maxConcurrent: 4)
        let session = WhipSession(
            client: WhipClientImpl(session: URLSession.shared),
            budget: budget
        )

        do {
            try await session.start(
                endpointURL: URL(string: Self.endpointURL)!,
                config: PublishConfig(
                    videoCodec: "VP8",
                    videoBitrate: 500_000,
                    keyframeInterval: 2.0,
                    audioStereo: true,
                    audioBitrate: 64_000
                )
            )

            // Wait briefly for connection
            try await Task.sleep(for: .milliseconds(500))
            let state = await session.state
            #expect(state == .live, "State should be live after successful publish")

            // Stop
            await session.stop()
            let finalState = await session.state
            #expect(finalState == .ended, "State should be ended after stop")
        } catch {
            // If start fails (no WebRTC compiled), that's expected in non-WebRTC builds
            Issue.record("Session start failed: \(error)")
            await session.stop()
        }
    }

    // MARK: - Helpers

    /// Fetches active paths from the MediaMTX API.
    private func fetchActivePaths() async throws -> [String] {
        guard let url = URL(string: "\(Self.apiURL)/v3/paths/list") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        struct PathsResponse: Decodable {
            let items: [PathItem]?
            struct PathItem: Decodable {
                let name: String?
            }
        }
        let decoded = try JSONDecoder().decode(PathsResponse.self, from: data)
        return decoded.items?.compactMap(\.name) ?? []
    }
}
