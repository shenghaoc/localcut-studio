import Foundation
import CoreMedia
import LocalCutCore

// MARK: - Interchange Timebase

/// Exact rational time representation used by the interchange serializers.
/// All emitted times are snapped to frame boundaries aligned to this timebase.
///
/// For fractional rates like 23.976 fps, the rational form is preserved:
/// `rate = 24000`, `frameDurationTimescale = 1001`, so
/// `RationalTime(value: 1001, rate: 24000)` equals exactly one frame.
struct InterchangeTimebase: Sendable {
    /// Numerator of the rational frame rate (e.g. 24000 for 23.976 fps).
    let rate: Int
    /// Denominator of the rational frame rate (e.g. 1001 for 23.976 fps).
    let frameDurationTimescale: Int

    init(rate: Int, frameDurationTimescale: Int) {
        precondition(rate > 0 && frameDurationTimescale > 0,
                     "InterchangeTimebase: rate and frameDurationTimescale must be positive")
        self.rate = rate
        self.frameDurationTimescale = frameDurationTimescale
    }

    /// `CMTime` timescale derived from `rate`.
    var timescale: CMTimeScale { CMTimeScale(rate) }
    /// Nominal (rounded) integer FPS for timecode formatting.
    /// For 23.976→24, 29.97→30, 59.94→60.
    var nominalFPS: Int {
        Int((Double(rate) / Double(frameDurationTimescale)).rounded())
    }

    /// Duration of one frame as a `CMTime`.
    var frameDuration: CMTime {
        CMTime(value: CMTimeValue(frameDurationTimescale), timescale: timescale)
    }

    /// Micro-gap collapse threshold: `max(1 ms, 0.5 / fps)`.
    var microGapThreshold: CMTime {
        let oneMillisecond = CMTime(value: 1, timescale: 1_000)
        let halfFrame = CMTime(value: CMTimeValue(frameDurationTimescale),
                               timescale: CMTimeScale(rate * 2))
        return halfFrame > oneMillisecond ? halfFrame : oneMillisecond
    }

    /// Converts a frame count to `CMTime`.
    func time(frames: Int) -> CMTime {
        CMTime(value: CMTimeValue(clamping: rationalValue(frames: frames)), timescale: timescale)
    }

    /// Converts a `CMTime` to frame count, clamping negative to 0.
    func frames(time: CMTime) -> Int {
        guard time.isNumeric, time.isValid, !time.isIndefinite, !time.isNegativeInfinity else { return 0 }
        let seconds = max(0, time.seconds)
        let raw = seconds * Double(rate) / Double(frameDurationTimescale)
        guard raw.isFinite else { return 0 }
        if raw >= Double(Int.max) { return Int.max }
        return Int(raw.rounded(.toNearestOrAwayFromZero))
    }

    /// Snaps an arbitrary `CMTime` to the nearest frame boundary.
    func snapToFrames(_ time: CMTime) -> CMTime {
        self.time(frames: frames(time: time))
    }

    /// The rate value for OTIO `RationalTime` (same as `rate`).
    var rationalTimeRate: Int { rate }

    /// OTIO RationalTime value for a frame count at this timebase.
    func rationalValue(frames: Int) -> Int {
        let (value, overflow) = frames.multipliedReportingOverflow(by: frameDurationTimescale)
        guard !overflow else { return frames < 0 ? Int.min : Int.max }
        return value
    }
}

// MARK: - Interchange Rate Selection

/// Selects the interchange timebase for a project document.
///
/// Priority:
/// 1. `project.frameRate` when finite and > 0.
/// 2. 30 fps fallback. `MediaRef` does not currently persist source FPS.
func interchangeTimebase(for doc: ProjectDocument) -> InterchangeTimebase {
    let fps = doc.frameRate
    if fps.isFinite, fps > 0 {
        return timebase(for: fps)
    }

    return timebase(for: 30)
}

/// Builds a timebase from a Double frame rate, preserving exact rational
/// representation for fractional rates (23.976, 29.97, 59.94).
private func timebase(for fps: Double) -> InterchangeTimebase {
    // Check for well-known fractional rates.
    if abs(fps - 23.976) < 0.002 {
        return InterchangeTimebase(rate: 24000, frameDurationTimescale: 1001)
    }
    if abs(fps - 29.97) < 0.002 {
        return InterchangeTimebase(rate: 30000, frameDurationTimescale: 1001)
    }
    if abs(fps - 59.94) < 0.005 {
        return InterchangeTimebase(rate: 60000, frameDurationTimescale: 1001)
    }
    if abs(fps - 47.952) < 0.005 {
        return InterchangeTimebase(rate: 48000, frameDurationTimescale: 1001)
    }

    // Integer rate (or close enough).
    let rounded = Int(fps.rounded())
    return InterchangeTimebase(rate: max(1, rounded), frameDurationTimescale: 1)
}

// MARK: - Frame Snapping

/// Snaps all clips on a track to frame boundaries, preserving adjacency.
///
/// Adjacent clips (where `clip[i].timelineEnd ≈ clip[i+1].timelineStart`)
/// remain adjacent after snapping: the shared boundary is snapped once and
/// both clips reference the same frame boundary.
func snapTrackClips(_ clips: [ClipDoc], timebase: InterchangeTimebase) -> [InterchangeClip] {
    guard !clips.isEmpty else { return [] }

    // Sort by timeline position.
    let sorted = clips.enumerated().sorted { $0.element.timelineStart.cmTime < $1.element.timelineStart.cmTime }
    var result: [InterchangeClip] = []
    var previousRawEnd: CMTime?

    for (index, item) in sorted.enumerated() {
        let clip = item.element
        let rawStart = clip.timelineStart.cmTime
        let rawSourceDuration = clip.duration.cmTime
        let rawOutputDuration = outputDuration(for: clip)
        let rawEnd = rawStart + rawOutputDuration

        let snappedStart: CMTime
        if index > 0, let prev = result.last {
            // Check adjacency against raw clip boundaries, then share the
            // snapped boundary to avoid rounding a micro-gap into a frame gap.
            let rawGap = rawStart - (previousRawEnd ?? prev.timelineEnd)
            let negThreshold = CMTime.zero - timebase.microGapThreshold
            if rawGap < timebase.microGapThreshold, rawGap > negThreshold {
                // Adjacent: share the boundary.
                snappedStart = prev.timelineEnd
            } else {
                snappedStart = timebase.snapToFrames(rawStart)
            }
        } else {
            snappedStart = timebase.snapToFrames(rawStart)
        }

        let snappedEnd = timebase.snapToFrames(rawEnd)
        let snappedDuration = snappedEnd - snappedStart

        // Check for zero-frame clip.  Do NOT update previousRawEnd here —
        // the dropped clip's raw boundary must not influence gap calculations
        // for subsequent clips.
        if snappedDuration <= .zero {
            continue // Dropped; warning emitted by caller.
        }

        let sourceStart = timebase.snapToFrames(clip.sourceStart.cmTime)
        let sourceDuration = timebase.snapToFrames(rawSourceDuration)

        result.append(InterchangeClip(
            doc: clip,
            sourceIndex: item.offset,
            timelineStart: snappedStart,
            timelineDuration: snappedDuration,
            sourceStart: sourceStart,
            sourceDuration: sourceDuration,
            outputDuration: snappedDuration))
        previousRawEnd = rawEnd
    }

    return result
}

private func outputDuration(for clip: ClipDoc) -> CMTime {
    guard let speedCurve = clip.speedCurve,
          TimeRemapping.hasNonIdentitySpeed(speedCurve) else {
        return clip.duration.cmTime
    }
    return TimeRemapping.outputDuration(
        sourceDuration: clip.duration.cmTime,
        speedCurve: speedCurve)
}

// MARK: - Interchange Clip

/// A clip whose timing has been snapped to frame boundaries.
struct InterchangeClip: Sendable {
    let doc: ClipDoc
    let sourceIndex: Int
    let timelineStart: CMTime
    let timelineDuration: CMTime
    let sourceStart: CMTime
    let sourceDuration: CMTime
    /// Output duration on the timeline (accounts for speed curves).
    /// Equal to `timelineDuration` for clips without speed ramps.
    let outputDuration: CMTime

    var timelineEnd: CMTime { timelineStart + outputDuration }
    var mediaID: UUID { doc.mediaID }
}

// MARK: - Micro-Gap Collapse

/// Collapses gaps smaller than the threshold between adjacent items.
/// Returns the adjusted start times.
func collapseGaps(items: [(start: CMTime, end: CMTime)],
                  threshold: CMTime) -> [(start: CMTime, end: CMTime)] {
    guard items.count > 1 else { return items }
    var result: [(start: CMTime, end: CMTime)] = [items[0]]
    for index in 1..<items.count {
        let prev = result[result.count - 1]
        let current = items[index]
        let gap = current.start - prev.end
        if gap > .zero, gap < threshold {
            // Collapse: snap current start to previous end.
            result.append((start: prev.end, end: current.end))
        } else {
            result.append(current)
        }
    }
    return result
}

// MARK: - Timecode Formatting

/// Formats a `CMTime` as SMPTE non-drop-frame timecode: `HH:MM:SS:FF`.
func formatTimecode(_ time: CMTime, timebase: InterchangeTimebase) -> String {
    guard time.isNumeric, time.isValid, !time.isIndefinite else {
        return "00:00:00:00"
    }

    let totalFrames = timebase.frames(time: time)
    let fps = timebase.nominalFPS
    let framesPerHour = fps * 3600
    let framesPerMinute = fps * 60

    let hours = totalFrames / framesPerHour
    let remainingAfterHours = totalFrames % framesPerHour
    let minutes = remainingAfterHours / framesPerMinute
    let remainingAfterMinutes = remainingAfterHours % framesPerMinute
    let seconds = remainingAfterMinutes / fps
    let frames = remainingAfterMinutes % fps

    return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
}

/// Formats a frame count as SMPTE NDF timecode at the given timebase.
func formatTimecode(frames totalFrames: Int, timebase: InterchangeTimebase) -> String {
    let fps = timebase.nominalFPS
    let framesPerHour = fps * 3600
    let framesPerMinute = fps * 60

    let hours = totalFrames / framesPerHour
    let remainingAfterHours = totalFrames % framesPerHour
    let minutes = remainingAfterHours / framesPerMinute
    let remainingAfterMinutes = remainingAfterHours % framesPerMinute
    let seconds = remainingAfterMinutes / fps
    let frames = remainingAfterMinutes % fps

    return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
}

// MARK: - OTIO RationalTime Helper

/// Builds an OTIO `RationalTime` dictionary from a snapped `CMTime`.
func otioRationalTime(_ time: CMTime, timebase: InterchangeTimebase) -> [String: Any] {
    let frames = timebase.frames(time: time)
    return [
        "OTIO_SCHEMA": "RationalTime.1",
        "value": timebase.rationalValue(frames: frames),
        "rate": timebase.rate,
    ]
}

/// Builds an OTIO `TimeRange` dictionary.
func otioTimeRange(start: CMTime, duration: CMTime,
                   timebase: InterchangeTimebase) -> [String: Any] {
    [
        "OTIO_SCHEMA": "TimeRange.1",
        "start_time": otioRationalTime(start, timebase: timebase),
        "duration": otioRationalTime(duration, timebase: timebase),
    ]
}

// MARK: - Speed Curve Helpers

/// Checks whether a speed curve is effectively uniform, including Bezier handle
/// values. Used by both OTIO and EDL serializers to decide whether to emit a
/// non-uniform speed warning.
func isSpeedCurveUniform(_ curve: Keyframed<Float>) -> Bool {
    let speed = TimeRemapping.clampedSpeed(curve.defaultValue)
    return curve.keyframes.allSatisfy { kf in
        abs(TimeRemapping.clampedSpeed(kf.value) - speed) < 0.0001
            && (kf.incomingHandle == nil || abs(TimeRemapping.clampedSpeed(kf.incomingHandle!.y) - speed) < 0.0001)
            && (kf.outgoingHandle == nil || abs(TimeRemapping.clampedSpeed(kf.outgoingHandle!.y) - speed) < 0.0001)
    }
}
