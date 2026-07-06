import Foundation
import os
import Testing
import CoreVideo
@testable import LocalCut_Studio

@Suite("WHIP publish", .serialized)
struct WhipPublishTests {
    private nonisolated final class TimeProbe: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: State())

        struct State {
            var now: TimeInterval = 0
            var sleeps: [TimeInterval] = []
        }

        init(now: TimeInterval) {
            lock.withLock { $0.now = now }
        }

        var now: TimeInterval {
            lock.withLock { $0.now }
        }

        func setNow(_ value: TimeInterval) {
            lock.withLock { $0.now = value }
        }

        func recordSleep(_ duration: TimeInterval) {
            lock.withLock { $0.sleeps.append(duration) }
        }

        var sleeps: [TimeInterval] {
            lock.withLock { $0.sleeps }
        }
    }

    private nonisolated final class URLProtocolStub: URLProtocol {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            do {
                let handler = try #require(Self.handler)
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        static func reset() {
            requests = []
            handler = nil
        }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeTestBuffer(width: Int = 16, height: Int = 16) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer)
        return try #require(pixelBuffer)
    }

    @Test("Publish parses quoted ICE Link headers with TURN credentials")
    func publishParsesQuotedIceServerLinks() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let endpoint = try #require(URL(string: "https://example.test/whip"))
        URLProtocolStub.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: [
                    "Location": "/whip/resource",
                    "ETag": "abc",
                    "Link": "<turn:turn.example.test>; rel=\"ice-server\"; username=\"user\"; credential=\"pass\""
                ])!
            return (response, Data("answer".utf8))
        }

        let client = WhipClientImpl(session: session())
        let result = try await client.publish(endpoint: endpoint, offerSdp: "offer", authToken: "secret")

        #expect(result.resourceUrl.absoluteString == "https://example.test/whip/resource")
        #expect(result.etag == "abc")
        #expect(result.answerSdp == "answer")
        #expect(result.iceServers == [
            ICEServerInfo(
                url: try #require(URL(string: "turn:turn.example.test")),
                username: "user",
                credential: "pass")
        ])
    }

    @Test("ICE restart PATCH sends wildcard If-Match and bearer token")
    func patchIceRestartSendsWildcardValidator() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.value(forHTTPHeaderField: "If-Match") == "*")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "next"])!
            return (response, Data("answer".utf8))
        }

        let client = WhipClientImpl(session: session())
        let resource = try #require(URL(string: "https://example.test/whip/resource"))
        let result = try await client.patchIceRestart(
            resourceUrl: resource,
            sdpFragment: "restart",
            etag: "old",
            authToken: "secret")

        #expect(result.answerSdp == "answer")
        #expect(result.newEtag == "next")
        #expect(URLProtocolStub.requests.count == 1)
    }

    @Test("Non-WebRTC video tap stores the latest frame without deadlocking")
    func nonWebRTCVideoTapStoresLatestFrame() throws {
        #if !LOCALCUT_ENABLE_WEBRTC
        let tap = VideoPublishTap()
        let buffer = try makeTestBuffer()
        tap.capturePixelBuffer(buffer)
        #expect(tap.currentPixelBuffer != nil)
        tap.close()
        #else
        #expect(Bool(true))
        #endif
    }

    @Test("Reconnect controller applies grace period and backoff ladder")
    func reconnectControllerTiming() async throws {
        let probe = TimeProbe(now: 100)
        let controller = ReconnectController(
            clock: { probe.now },
            sleep: { duration in probe.recordSleep(duration) }
        )

        controller.markDisconnected()
        probe.setNow(101.25)
        try await controller.waitForGracePeriod()
        #expect(probe.sleeps == [1.75])

        for expected in [2.0, 4.0, 8.0, 16.0, 16.0] {
            controller.advanceAttempt()
            #expect(controller.backoffDuration == expected)
        }
        #expect(controller.attemptCount == controller.maxAttempts)
        #expect(!controller.canAttemptReconnect)
    }

    @Test("Reconnect controller resets ICE restart validator state")
    func reconnectControllerIceRestartState() {
        let controller = ReconnectController()
        #expect(controller.shouldTryIceRestart)

        controller.updateETag("etag-1")
        #expect(controller.currentETag == "etag-1")

        controller.patchFailed()
        #expect(!controller.shouldTryIceRestart)

        controller.resetETag()
        #expect(controller.currentETag == nil)
        #expect(controller.shouldTryIceRestart)
    }

    @Test("ICE restart body is an SDP fragment, not a full session description")
    func iceRestartFragmentOmitsSessionDescriptionLines() {
        let fullSdp = """
        v=0
        o=- 1 2 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:sessionUfrag
        a=ice-pwd:sessionPwd
        a=fingerprint:sha-256 00:11:22
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:0
        a=ice-ufrag:mediaUfrag
        a=ice-pwd:mediaPwd
        a=candidate:1 1 udp 2122260223 192.0.2.1 54400 typ host
        a=end-of-candidates
        """

        let fragment = IceSdpFragmentBuilder.restartFragment(from: fullSdp)

        #expect(!fragment.contains("v=0"))
        #expect(!fragment.contains("o=-"))
        #expect(fragment.contains("m=video"))
        #expect(fragment.contains("a=mid:0"))
        #expect(fragment.contains("a=ice-ufrag:mediaUfrag"))
        #expect(fragment.contains("a=ice-pwd:mediaPwd"))
        #expect(fragment.contains("a=candidate:1"))
        #expect(fragment.hasSuffix("\r\n"))
    }

    @MainActor
    @Test("Publish settings do not send hidden stream keys to tokenless endpoints")
    func publishSettingsDoNotSendTokenToTokenlessEndpoint() {
        let settings = PublishSettings()
        settings.endpointType = .mediaMTX
        settings.endpointURL = PublishEndpointType.mediaMTX.defaultEndpointURL
        settings.bearerToken = "hidden-token"
        settings.rememberToken = false

        #expect(settings.tokenForCurrentEndpoint() == nil)
        #expect(settings.redactedTokenDisplay().isEmpty)
    }

    @MainActor
    @Test("Endpoint type changes reset defaults and clear hidden tokens")
    func endpointTypeChangeResetsDefaultsAndClearsToken() {
        let model = EditorModel()
        let state = PublishPanelState()
        state.endpointType = .twitch
        state.endpointURL = PublishEndpointType.twitch.defaultEndpointURL
        state.bearerToken = "stream-key"
        state.rememberToken = true

        state.endpointType = .mediaMTX
        state.endpointTypeDidChange(from: .twitch, model: model)

        #expect(state.endpointURL == PublishEndpointType.mediaMTX.defaultEndpointURL)
        #expect(state.bearerToken.isEmpty)
        #expect(!state.rememberToken)
        #expect(state.selectedCodec == .h264Baseline)
        #expect(!state.availableCodecs.contains(.av1))
    }

    @MainActor
    @Test("Project documents exclude session-only publish tokens")
    func projectDocumentExcludesPublishToken() throws {
        let model = EditorModel()
        model.publishSettings.bearerToken = "super-secret-stream-key"

        let data = try model.makeDocumentForSave(forBundle: true).encoded()
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("super-secret-stream-key"))
        #expect(!json.contains("publish"))
    }
}
