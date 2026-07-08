import Foundation
import CoreVideo
import os

#if LOCALCUT_ENABLE_WEBRTC
import WebRTC
#endif

nonisolated final class VideoPublishTap: @unchecked Sendable {
    #if LOCALCUT_ENABLE_WEBRTC
    private var videoSource: RTCVideoSource?
    private var capturer: TapCapturer?

    init() {}

    nonisolated func attach(to factory: RTCPeerConnectionFactory) -> RTCVideoSource {
        lock.withLock { state in
            if let videoSource { return videoSource }
            let source = factory.videoSource()
            videoSource = source
            capturer = TapCapturer(source: source)
            return source
        }
    }

    nonisolated func detachFromWebRTC() {
        lock.withLock { _ in
            videoSource = nil
            capturer = nil
        }
    }
    #else
    nonisolated(unsafe) private(set) var latestPixelBuffer: CVPixelBuffer?
    init() {}
    nonisolated func detachFromWebRTC() {}
    #endif

    /// @unchecked Sendable because CVPixelBuffer is a reference type not
    /// annotated Sendable; the lock provides the necessary thread safety.
    private struct State: @unchecked Sendable {
        var isClosed = false
        var isInFlight = false
        var pendingBuffer: CVPixelBuffer?
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    nonisolated func capturePixelBuffer(_ buffer: CVPixelBuffer) {
        let shouldDeliver = lock.withLock { state -> Bool in
            guard !state.isClosed else { return false }
            if state.isInFlight {
                state.pendingBuffer = buffer
                return false
            }
            state.isInFlight = true
            return true
        }
        guard shouldDeliver else { return }
        deliverFrame(buffer)
    }

    nonisolated func close() {
        lock.withLock { state in
            guard !state.isClosed else { return }
            state.isClosed = true
            state.pendingBuffer = nil
            state.isInFlight = false
        }
    }

    private nonisolated func deliverFrame(_ buffer: CVPixelBuffer) {
        #if LOCALCUT_ENABLE_WEBRTC
        let activeCapturer = lock.withLock { _ in capturer }
        if let activeCapturer {
            let frame = RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
                rotation: ._0,
                timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            )
            activeCapturer.didCapture(frame)
        }
        #else
        lock.withLock { _ in latestPixelBuffer = buffer }
        #endif

        let next = lock.withLock { state -> CVPixelBuffer? in
            let pending = state.pendingBuffer
            state.pendingBuffer = nil
            if pending == nil { state.isInFlight = false }
            return pending
        }
        if let next { deliverFrame(next) }
    }
}

#if LOCALCUT_ENABLE_WEBRTC
private nonisolated final class TapCapturer: RTCVideoCapturer {
    init(source: RTCVideoSource) {
        super.init(delegate: source)
    }
    func didCapture(_ frame: RTCVideoFrame) {
        delegate?.capturer(self, didCapture: frame)
    }
}
#endif
