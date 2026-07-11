import Foundation
import CoreVideo
import os
import WebRTC

/// `@unchecked Sendable`: WebRTC source/capturer and frame delivery state
/// (`isClosed`, `isInFlight`, and `pendingBuffer`) are protected by `lock`.
public nonisolated final class VideoPublishTap: @unchecked Sendable {
    private var videoSource: RTCVideoSource?
    private var capturer: TapCapturer?

    public init() {}

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

    private let lock = OSAllocatedUnfairLock(initialState: ())
    private var isClosed = false
    private var isInFlight = false
    private var pendingBuffer: CVPixelBuffer?

    public nonisolated func capturePixelBuffer(_ buffer: CVPixelBuffer) {
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

    public nonisolated func close() {
        lock.withLock { _ in
            guard !isClosed else { return }
            isClosed = true
            pendingBuffer = nil
            isInFlight = false
        }
    }

    private nonisolated func deliverFrame(_ buffer: CVPixelBuffer) {
        let activeCapturer = lock.withLockUnchecked { _ in capturer }
        if let activeCapturer {
            let frame = RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
                rotation: ._0,
                timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            )
            activeCapturer.didCapture(frame)
        }

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

private nonisolated final class TapCapturer: RTCVideoCapturer {
    init(source: RTCVideoSource) {
        super.init(delegate: source)
    }
    func didCapture(_ frame: RTCVideoFrame) {
        delegate?.capturer(self, didCapture: frame)
    }
}
