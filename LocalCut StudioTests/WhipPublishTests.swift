import Foundation
import Testing
import CoreVideo
@testable import LocalCut_Studio

@Suite("WHIP publish", .serialized)
struct WhipPublishTests {
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
            offerSdp: "restart",
            etag: "old",
            authToken: "secret")

        #expect(result.answerSdp == "answer")
        #expect(result.newEtag == "next")
        #expect(URLProtocolStub.requests.count == 1)
    }

    @Test("Non-WebRTC video tap stores the latest frame without deadlocking")
    func nonWebRTCVideoTapStoresLatestFrame() throws {
        #if !canImport(WebRTC)
        let tap = VideoPublishTap()
        let buffer = try makeTestBuffer()
        tap.capturePixelBuffer(buffer)
        #expect(tap.latestPixelBuffer != nil)
        tap.close()
        #else
        #expect(true)
        #endif
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
