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
        lock.withLockUnchecked { _ in
            if let videoSource { return videoSource }
            let source = factory.videoSource()
            videoSource = source
            capturer = TapCapturer(source: source)
            return source
        }
    }

    nonisolated func detachFromWebRTC() {
        lock.withLockUnchecked { _ in
            videoSource = nil
            capturer = nil
        }
    }
    #else
    nonisolated(unsafe) private(set) var latestPixelBuffer: CVPixelBuffer?
    init() {}
    nonisolated func detachFromWebRTC() {}
    #endif

    private let lock = OSAllocatedUnfairLock(initialState: ())
    private var isClosed = false
    private var isInFlight = false
    private var pendingBuffer: CVPixelBuffer?

    nonisolated func capturePixelBuffer(_ buffer: CVPixelBuffer) {
        let shouldDeliver = lock.withLockUnchecked { _ -> Bool in
            guard !isClosed else { return false }
            if isInFlight {
                pendingBuffer = buffer
                return false
            }
            isInFlight = true
            return true
        }
        if shouldDeliver {
            deliverFrame(buffer)
        }
    }

    nonisolated func close() {
        lock.withLock { _ in
            guard !isClosed else { return }
            isClosed = true
            pendingBuffer = nil
            isInFlight = false
        }
    }

    private nonisolated func deliverFrame(_ buffer: CVPixelBuffer) {
        #if LOCALCUT_ENABLE_WEBRTC
        let activeCapturer = lock.withLockUnchecked { _ in capturer }
        if let activeCapturer {
            let frame = RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
                rotation: ._0,
                timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            )
            activeCapturer.didCapture(frame)
        }
        #else
        lock.withLockUnchecked { _ in latestPixelBuffer = buffer }
        #endif

        let next = lock.withLockUnchecked { _ -> CVPixelBuffer? in
            let n = pendingBuffer
            pendingBuffer = nil
            if n == nil { isInFlight = false }
            return n
        }
        if let next {
            deliverFrame(next)
        }
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
