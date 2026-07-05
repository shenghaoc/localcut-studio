import Foundation
import os

nonisolated enum WhipError: Error, Sendable, LocalizedError {
    case rejectedOffer
    case auth
    case notFound
    case retryable(any Error & Sendable)
    case invalidResponse
    case httpStatus(Int, Data?)
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .rejectedOffer: "The server rejected the SDP offer."
        case .auth: "Authentication failed. Check your stream key."
        case .notFound: "The publish endpoint was not found."
        case .retryable: "The server is temporarily unavailable."
        case .invalidResponse: "The server returned an unexpected response."
        case .httpStatus(let code, _): "Unexpected HTTP status \(code)."
        case .invalidState(let message): message
        }
    }
}

nonisolated struct WhipPreconditionError: Error, Sendable {
    let statusCode: Int
    var errorDescription: String? { "Precondition failed (HTTP \(statusCode))." }
}

nonisolated struct WhipServerError: Error, Sendable {
    let statusCode: Int
    var errorDescription: String? { "Server error (HTTP \(statusCode))." }
}

nonisolated struct WhipResource: Sendable {
    let resourceURL: URL
    let etag: String?
    let iceServers: [ICEServerInfo]
    let answerSDP: String
}

protocol WhipClient: Sendable {
    func publish(endpoint: URL, offerSdp: String, authToken: String?) async throws -> (resourceUrl: URL, etag: String, iceServers: [ICEServerInfo], answerSdp: String)
    func patchIceRestart(resourceUrl: URL, sdpFragment: String, etag: String, authToken: String?) async throws -> (answerSdp: String, newEtag: String)
    func teardown(resourceUrl: URL, authToken: String?) async
}

actor WhipClientImpl: WhipClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func publish(endpoint: URL, offerSdp: String, authToken: String?) async throws -> (resourceUrl: URL, etag: String, iceServers: [ICEServerInfo], answerSdp: String) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("application/sdp", forHTTPHeaderField: "Accept")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = offerSdp.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WhipError.invalidResponse }

        switch http.statusCode {
        case 200, 201: break
        default: throw mapHTTPError(statusCode: http.statusCode, data: data)
        }

        guard let answerSdp = String(data: data, encoding: .utf8), !answerSdp.isEmpty else {
            throw WhipError.invalidResponse
        }

        guard let locationString = http.value(forHTTPHeaderField: "Location"),
              let resourceUrl = URL(string: locationString, relativeTo: endpoint) else {
            throw WhipError.invalidResponse
        }

        let etag = http.value(forHTTPHeaderField: "ETag") ?? ""
        let linkHeaders = http.value(forHTTPHeaderField: "Link").map { [$0] } ?? []
        let iceServers = LinkHeaderParser.parse(headerValues: linkHeaders)

        return (resourceUrl: resourceUrl, etag: etag, iceServers: iceServers, answerSdp: answerSdp)
    }

    func patchIceRestart(resourceUrl: URL, sdpFragment: String, etag: String, authToken: String?) async throws -> (answerSdp: String, newEtag: String) {
        var request = URLRequest(url: resourceUrl)
        request.httpMethod = "PATCH"
        request.setValue("application/trickle-ice-sdpfrag", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-Match")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = sdpFragment.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WhipError.invalidResponse }

        switch http.statusCode {
        case 200, 204: break
        default: throw mapHTTPError(statusCode: http.statusCode, data: data)
        }

        let newEtag = http.value(forHTTPHeaderField: "ETag") ?? etag
        let answerSdp = String(data: data, encoding: .utf8) ?? ""
        return (answerSdp: answerSdp, newEtag: newEtag)
    }

    func teardown(resourceUrl: URL, authToken: String?) async {
        var request = URLRequest(url: resourceUrl)
        request.httpMethod = "DELETE"
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await session.data(for: request)
    }

    private func mapHTTPError(statusCode: Int, data: Data?) -> WhipError {
        switch statusCode {
        case 400: return .rejectedOffer
        case 401, 403: return .auth
        case 404: return .notFound
        case 412, 428: return .retryable(WhipPreconditionError(statusCode: statusCode))
        case 500...599: return .retryable(WhipServerError(statusCode: statusCode))
        default: return .httpStatus(statusCode, data)
        }
    }
}
