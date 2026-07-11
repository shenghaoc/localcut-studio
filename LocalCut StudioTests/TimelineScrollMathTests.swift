import Testing
import CoreGraphics
@testable import LocalCut_Studio

// TimelineScrollMath is the pure layer behind the timeline page-scroll
// buttons, the center-playhead action, the accessibility adjustable action,
// and the clip-focus scroll targets. Locking it down catches the next
// regression in this surface as a red-to-green test rather than a UI bug.

@Suite("TimelineScrollMath: pure helpers")
struct TimelineScrollMathTests {

    // MARK: - pageSeconds

    @Test("Page seconds equals 640 / pps when zoomed out")
    func pageSecondsZoomedOut() {
        // 640 pt / 80 pt-per-second → 8 seconds per page.
        #expect(abs(TimelineScrollMath.pageSeconds(pps: 80) - 8) < 1e-9)
    }

    @Test("Page seconds is floored at 5 s when zoomed in")
    func pageSecondsZoomedInClamps() {
        // 640 pt / 200 pt-per-second → 3.2, floored at 5.
        #expect(TimelineScrollMath.pageSeconds(pps: 200) == 5)
    }

    @Test("Page seconds keeps a sane value at degenerate pps (0)")
    func pageSecondsAtZeroPps() {
        // pps is clamped to 1 in the formula so we never divide by zero.
        // 640 / 1 = 640 s.
        #expect(TimelineScrollMath.pageSeconds(pps: 0) == 640)
    }

    // MARK: - viewportSeconds + viewportCentreSeconds

    @Test("Viewport seconds is viewport-width / pps")
    func viewportSecondsSplit() {
        #expect(abs(TimelineScrollMath.viewportSeconds(viewportWidth: 800, pps: 100) - 8) < 1e-9)
        #expect(abs(TimelineScrollMath.viewportSeconds(viewportWidth: 800, pps: 0) - 800) < 1e-9)
    }

    @Test("Viewport centre is leading + half the viewport's seconds")
    func viewportCentre() {
        // Scrolled so the leading edge is at t=10, viewport is 8 s wide
        // (800 pt / 100 pt-per-second) → centre at t=14.
        let centre = TimelineScrollMath.viewportCentreSeconds(
            scrollLeadingSeconds: 10,
            viewportWidth: 800,
            pps: 100)
        #expect(abs(centre - 14) < 1e-9)
    }

    // MARK: - clampedTarget

    struct ClampedTargetCase: CustomTestStringConvertible {
        let target: Double
        let totalDuration: Double
        let expected: Double
        var testDescription: String { "clamp(\(target), dur:\(totalDuration)) == \(expected)" }
    }

    @Test("clampedTarget pins to valid range", arguments: [
        ClampedTargetCase(target: -5, totalDuration: 30, expected: 0),
        ClampedTargetCase(target: 100, totalDuration: 30, expected: 30),
        ClampedTargetCase(target: 10, totalDuration: 0, expected: 0),
        ClampedTargetCase(target: 0, totalDuration: 0, expected: 0),
        ClampedTargetCase(target: 5, totalDuration: -10, expected: 0),
    ])
    func clampedTarget(_ cs: ClampedTargetCase) {
        #expect(TimelineScrollMath.clampedTarget(cs.target, totalDuration: cs.totalDuration) == cs.expected)
    }

    // MARK: - Ruler accessibility adjustment

    struct RulerCase: CustomTestStringConvertible {
        let currentTime: Double
        let totalDuration: Double
        let tickStep: Double
        let increment: Bool
        let expected: Double?
        var testDescription: String {
            let dir = increment ? "++" : "--"
            return "ruler(\(currentTime), step:\(tickStep), \(dir)) == \(expected.map { String($0) } ?? "nil")"
        }
    }

    @Test("Ruler adjustment target", arguments: [
        // Tick step clamping
        RulerCase(currentTime: 10, totalDuration: 30, tickStep: 0.1, increment: true, expected: 10.25),
        RulerCase(currentTime: 10, totalDuration: 30, tickStep: 30, increment: true, expected: 15),
        // Boundary clamping
        RulerCase(currentTime: 0.1, totalDuration: 30, tickStep: 1, increment: false, expected: 0),
        RulerCase(currentTime: 29.5, totalDuration: 30, tickStep: 1, increment: true, expected: 30),
        // Empty project
        RulerCase(currentTime: 0, totalDuration: 0, tickStep: 1, increment: true, expected: nil),
    ])
    func rulerAdjustment(_ cs: RulerCase) {
        #expect(TimelineScrollMath.rulerAdjustmentTarget(
            currentTime: cs.currentTime, totalDuration: cs.totalDuration,
            tickStep: cs.tickStep, increment: cs.increment) == cs.expected)
    }

    // MARK: - Page-scroll integration math

    @Test("Page-right from middle of project advances by pageSeconds")
    func pageRightAdvances() {
        // Setup: pps=80 → page=8s. Leading at t=10, viewport 8s wide → centre=14.
        // Page right → centre + 8 = 22, clamped to 30 → 22.
        let pps: CGFloat = 80
        let viewport: CGFloat = 640
        let leading: Double = 10
        let pageSeconds = TimelineScrollMath.pageSeconds(pps: pps)
        let centre = TimelineScrollMath.viewportCentreSeconds(
            scrollLeadingSeconds: leading,
            viewportWidth: viewport,
            pps: pps)
        let nextRaw = centre + pageSeconds
        let nextClamped = TimelineScrollMath.clampedTarget(nextRaw, totalDuration: 30)
        #expect(abs(nextClamped - 22) < 1e-9)
    }

    @Test("Page-left from start clamps to 0 instead of going negative")
    func pageLeftClampsAtStart() {
        let pps: CGFloat = 80
        let viewport: CGFloat = 640
        let leading: Double = 0
        let pageSeconds = TimelineScrollMath.pageSeconds(pps: pps)
        let centre = TimelineScrollMath.viewportCentreSeconds(
            scrollLeadingSeconds: leading,
            viewportWidth: viewport,
            pps: pps)
        // centre = 0 + 8/2 = 4, page left → 4 - 8 = -4, clamped to 0.
        let next = TimelineScrollMath.clampedTarget(centre - pageSeconds, totalDuration: 30)
        #expect(next == 0)
    }
}
