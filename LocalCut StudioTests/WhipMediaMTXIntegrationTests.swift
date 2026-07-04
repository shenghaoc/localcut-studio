import Foundation
import Testing
import LocalCutCore
@testable import LocalCut_Studio

/// MediaMTX WHIP integration test.
///
/// Verifies that LocalCut can publish to a real WHIP ingest endpoint
/// (MediaMTX running in a container), assert ingest, and tear down cleanly.
///
/// This test requires a container runtime (Docker/Podman) with MediaMTX running
/// on localhost:8889. Normal local test runs leave the suite disabled; CI must
/// run it through `run-mediamtx-whip-integration.sh`, which sets the opt-in
/// environment variable after starting the container.
@Suite(
    "MediaMTX WHIP integration",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LOCALCUT_RUN_MEDIAMTX_INTEGRATION"] == "1")
)
struct WhipMediaMTXIntegrationTests {

    private static let endpointURL = "http://localhost:8889/stream/test"
    private static let apiURL = "http://localhost:9997"

    /// Returns true if MediaMTX is reachable on localhost.
    private static func isMediaMTXAvailable() async -> Bool {
        guard let url = URL(string: "\(apiURL)/v3/config/get") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    @Test("WHIP POST returns SDP answer from MediaMTX")
    func whipPostReturnsAnswer() async throws {
        guard await Self.isMediaMTXAvailable() else {
            Issue.record("MediaMTX not available on localhost:8889 — run Scripts/run-mediamtx-whip-integration.sh")
            return
        }

        let client = WhipClientImpl(session: URLSession.shared)

        // Minimal SDP offer for a sendonly audio+video session
        let offerSDP = """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=setup:actpass
        a=mid:0
        a=sendonly
        a=rtcp-mux
        a=rtpmap:96 VP8/90000
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=setup:actpass
        a=mid:1
        a=sendonly
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        """

        do {
            let result = try await client.publish(
                endpoint: URL(string: Self.endpointURL)!,
                offerSdp: offerSDP,
                authToken: nil
            )

            // Verify we got a valid response
            #expect(!result.answerSdp.isEmpty, "Answer SDP should not be empty")
            #expect(result.resourceUrl.absoluteString.contains("stream"), "Resource URL should reference the stream")

            // Teardown — send DELETE
            await client.teardown(resourceUrl: result.resourceUrl, authToken: nil)

            // Verify the path is no longer active
            try await Task.sleep(for: .milliseconds(500))
            let paths = try await fetchActivePaths()
            #expect(!paths.contains("test"), "Path 'test' should be inactive after teardown")
        } catch {
            Issue.record("WHIP publish failed: \(error)")
        }
    }

    @Test("Publish state reaches live and transitions to ended on stop")
    func publishStateTransitions() async throws {
        guard await Self.isMediaMTXAvailable() else {
            Issue.record("MediaMTX not available on localhost:8889 — run Scripts/run-mediamtx-whip-integration.sh")
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
