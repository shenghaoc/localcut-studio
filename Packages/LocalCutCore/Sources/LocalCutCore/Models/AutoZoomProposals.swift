import Foundation
import CoreMedia
import CoreGraphics

/// Generates deterministic zoom-pan proposals by clustering click bursts in a
/// screencast event log. Each proposal is review-before-apply.
public enum AutoZoomProposalGenerator {
    /// Parameters controlling how click events are clustered into bursts.
    public struct ClusteringParameters: Hashable, Sendable {
        /// Maximum time gap (seconds) between clicks in the same burst.
        public var maxGapSeconds: Double
        /// Maximum spatial distance (normalised 0…1) between clicks in the same burst.
        public var maxSpatialDistance: Double
        /// Minimum number of clicks to form a burst worth proposing.
        public var minClicksForBurst: Int
        /// Padding around the burst centre (normalised 0…1).
        public var burstPadding: Double
        /// Default zoom scale for proposals.
        public var defaultEndScale: Float
        /// Duration of the zoom-in portion (seconds).
        public var zoomInDuration: Double
        /// Duration to hold the zoom (seconds).
        public var holdDuration: Double
        /// Duration of the zoom-out portion (seconds).
        public var zoomOutDuration: Double

        public init(maxGapSeconds: Double = 1.5,
                    maxSpatialDistance: Double = 0.15,
                    minClicksForBurst: Int = 2,
                    burstPadding: Double = 0.1,
                    defaultEndScale: Float = 2.0,
                    zoomInDuration: Double = 0.3,
                    holdDuration: Double = 2.0,
                    zoomOutDuration: Double = 0.3) {
            self.maxGapSeconds = maxGapSeconds
            self.maxSpatialDistance = maxSpatialDistance
            self.minClicksForBurst = minClicksForBurst
            self.burstPadding = burstPadding
            self.defaultEndScale = defaultEndScale
            self.zoomInDuration = zoomInDuration
            self.holdDuration = holdDuration
            self.zoomOutDuration = zoomOutDuration
        }
    }

    /// Generate proposals from an event log.
    ///
    /// - Parameters:
    ///   - eventLog: The screencast event log to analyse.
    ///   - parameters: Clustering parameters.
    ///   - canvasSize: The canvas size for normalising positions.
    /// - Returns: An ordered list of proposals, sorted by time.
    public static func generateProposals(
        from eventLog: ScreencastEventLog,
        parameters: ClusteringParameters = ClusteringParameters(),
        canvasSize: CGSize
    ) -> [ZoomPanProposal] {
        guard eventLog.isSupportedSchema, !eventLog.events.isEmpty else { return [] }

        // Extract click events with positions.
        let clicks = eventLog.events.filter { $0.kind == .mouseDown && $0.position != nil }
        guard !clicks.isEmpty else { return [] }

        // Cluster clicks into bursts.
        let bursts = clusterClicks(clicks, parameters: parameters, canvasSize: canvasSize)
        guard !bursts.isEmpty else { return [] }

        // Generate proposals from bursts.
        return bursts.compactMap { burst in
            generateProposal(from: burst, parameters: parameters, canvasSize: canvasSize)
        }
    }

    // MARK: - Click Burst Clustering

    /// A cluster of click events forming a burst.
    struct ClickBurst {
        var events: [ScreencastEvent]
        var centreX: Double
        var centreY: Double
        var startTime: CMTime
        var endTime: CMTime
    }

    /// Cluster clicks into bursts using a simple gap-based algorithm.
    ///
    /// This is deterministic: given the same input events and parameters,
    /// it always produces the same output. The algorithm processes events
    /// in time order, starting a new cluster when the gap or distance exceeds
    /// the thresholds.
    static func clusterClicks(
        _ events: [ScreencastEvent],
        parameters: ClusteringParameters,
        canvasSize: CGSize
    ) -> [ClickBurst] {
        let sorted = events.sorted { $0.time < $1.time }
        var bursts: [ClickBurst] = []
        var current: ClickBurst?

        for event in sorted {
            guard let pos = event.position else { continue }
            // Normalise position to 0…1.
            let nx = Double(pos.x) / max(1, Double(canvasSize.width))
            let ny = Double(pos.y) / max(1, Double(canvasSize.height))

            if let cur = current {
                let gap = (event.time - cur.endTime).seconds
                let dx = nx - cur.centreX
                let dy = ny - cur.centreY
                let dist = sqrt(dx * dx + dy * dy)

                if gap <= parameters.maxGapSeconds && dist <= parameters.maxSpatialDistance {
                    // Add to current burst.
                    var updated = cur
                    updated.events.append(event)
                    updated.endTime = event.time
                    // Update centre (running average).
                    let n = Double(updated.events.count)
                    updated.centreX = (cur.centreX * (n - 1) + nx) / n
                    updated.centreY = (cur.centreY * (n - 1) + ny) / n
                    current = updated
                } else {
                    // Finalise current burst and start a new one.
                    if cur.events.count >= parameters.minClicksForBurst {
                        bursts.append(cur)
                    }
                    current = ClickBurst(
                        events: [event],
                        centreX: nx,
                        centreY: ny,
                        startTime: event.time,
                        endTime: event.time)
                }
            } else {
                current = ClickBurst(
                    events: [event],
                    centreX: nx,
                    centreY: ny,
                    startTime: event.time,
                    endTime: event.time)
            }
        }

        // Finalise the last burst.
        if let cur = current, cur.events.count >= parameters.minClicksForBurst {
            bursts.append(cur)
        }

        return bursts
    }

    /// Generate a proposal from a click burst.
    private static func generateProposal(
        from burst: ClickBurst,
        parameters: ClusteringParameters,
        canvasSize: CGSize
    ) -> ZoomPanProposal? {
        let totalDuration = parameters.zoomInDuration + parameters.holdDuration + parameters.zoomOutDuration
        let startOffset = max(0, parameters.zoomInDuration * 0.5)
        let proposalStart = CMTime(
            seconds: max(0, burst.startTime.seconds - startOffset),
            preferredTimescale: 600)
        let proposalDuration = CMTime(seconds: totalDuration, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: proposalStart, duration: proposalDuration)

        // Target point is the burst centre.
        let targetPoint = CGPoint(x: burst.centreX, y: burst.centreY)

        // Generate keyframes for the zoom animation.
        let zoomInTime = parameters.zoomInDuration
        let holdTime = parameters.holdDuration
        let zoomOutTime = parameters.zoomOutDuration

        let endScale = parameters.defaultEndScale
        let tx = Float(burst.centreX - 0.5) * (endScale - 1)
        let ty = Float(burst.centreY - 0.5) * (endScale - 1)
        let zoomed = Transform2D(translateX: tx, translateY: ty, scale: endScale, rotation: 0)

        let keyframes: [Keyframe<Transform2D>] = [
            Keyframe(time: CMTime(seconds: 0, preferredTimescale: 600), value: .identity),
            Keyframe(time: CMTime(seconds: zoomInTime, preferredTimescale: 600), value: zoomed),
            Keyframe(time: CMTime(seconds: zoomInTime + holdTime, preferredTimescale: 600), value: zoomed),
            Keyframe(time: CMTime(seconds: totalDuration, preferredTimescale: 600), value: .identity),
        ]

        return ZoomPanProposal(
            timeRange: timeRange,
            targetPoint: targetPoint,
            endScale: endScale,
            keyframes: keyframes,
            clickCount: burst.events.count)
    }
}
