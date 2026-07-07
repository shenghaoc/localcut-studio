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
        lock.lock()
        defer { lock.unlock() }
        if let videoSource { return videoSource }
        let source = factory.videoSource()
        videoSource = source
        capturer = TapCapturer(source: source)
        return source
    }

    nonisolated func detachFromWebRTC() {
        lock.lock()
        videoSource = nil
        capturer = nil
        lock.unlock()
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
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        if isInFlight {
            pendingBuffer = buffer
            lock.unlock()
            return
        }
        isInFlight = true
        lock.unlock()
        deliverFrame(buffer)
    }

    nonisolated func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        pendingBuffer = nil
        isInFlight = false
        lock.unlock()
    }

    private nonisolated func deliverFrame(_ buffer: CVPixelBuffer) {
        #if LOCALCUT_ENABLE_WEBRTC
        lock.lock()
        let activeCapturer = capturer
        lock.unlock()
        if let activeCapturer {
            let frame = RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
                rotation: ._0,
                timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            )
            activeCapturer.didCapture(frame)
        }
        #else
        lock.lock()
        latestPixelBuffer = buffer
        lock.unlock()
        #endif

        lock.lock()
        let next = pendingBuffer
        pendingBuffer = nil
        if let next {
            lock.unlock()
            deliverFrame(next)
        } else {
            isInFlight = false
            lock.unlock()
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
