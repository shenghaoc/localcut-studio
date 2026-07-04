import Foundation
import CoreVideo

#if canImport(WebRTC)
import WebRTC
#endif

nonisolated final class VideoPublishTap: @unchecked Sendable {
    #if canImport(WebRTC)
    let videoSource: RTCVideoSource
    private let capturer: TapCapturer

    init(videoSource: RTCVideoSource) {
        self.videoSource = videoSource
        self.capturer = TapCapturer(source: videoSource)
    }

    convenience init(factory: RTCPeerConnectionFactory) {
        let source = factory.videoSource()
        self.init(videoSource: source)
    }
    #else
    nonisolated(unsafe) private(set) var latestPixelBuffer: CVPixelBuffer?
    init() {}
    #endif

    private let lock = NSLock()
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
        #if canImport(WebRTC)
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
            rotation: ._0,
            timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
        capturer.didCapture(frame)
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

#if canImport(WebRTC)
private nonisolated final class TapCapturer: RTCVideoCapturer {
    init(source: RTCVideoSource) {
        super.init(delegate: source)
    }
    func didCapture(_ frame: RTCVideoFrame) {
        delegate?.capturer(self, didCapture: frame)
    }
}
#endif
