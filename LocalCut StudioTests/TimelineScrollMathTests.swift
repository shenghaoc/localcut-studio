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

    @Test("clampedTarget pins negatives to 0")
    func clampedTargetNegative() {
        #expect(TimelineScrollMath.clampedTarget(-5, totalDuration: 30) == 0)
    }

    @Test("clampedTarget pins past-end to totalDuration")
    func clampedTargetPastEnd() {
        #expect(TimelineScrollMath.clampedTarget(100, totalDuration: 30) == 30)
    }

    @Test("clampedTarget returns 0 for an empty project")
    func clampedTargetEmptyProject() {
        #expect(TimelineScrollMath.clampedTarget(10, totalDuration: 0) == 0)
        #expect(TimelineScrollMath.clampedTarget(0, totalDuration: 0) == 0)
    }

    @Test("clampedTarget protects against a negative totalDuration argument")
    func clampedTargetNegativeDuration() {
        // Math defensively floors totalDuration at 0 so callers can pass an
        // uninitialised model.totalDuration without splattering negatives.
        #expect(TimelineScrollMath.clampedTarget(5, totalDuration: -10) == 0)
    }

    // MARK: - Ruler accessibility adjustment

    @Test("Ruler adjustment clamps the tick step to a usable range")
    func rulerAdjustmentClampsStep() {
        #expect(TimelineScrollMath.rulerAdjustmentTarget(
            currentTime: 10, totalDuration: 30, tickStep: 0.1, increment: true) == 10.25)
        #expect(TimelineScrollMath.rulerAdjustmentTarget(
            currentTime: 10, totalDuration: 30, tickStep: 30, increment: true) == 15)
    }

    @Test("Ruler adjustment clamps at both project boundaries")
    func rulerAdjustmentClampsBoundaries() {
        #expect(TimelineScrollMath.rulerAdjustmentTarget(
            currentTime: 0.1, totalDuration: 30, tickStep: 1, increment: false) == 0)
        #expect(TimelineScrollMath.rulerAdjustmentTarget(
            currentTime: 29.5, totalDuration: 30, tickStep: 1, increment: true) == 30)
    }

    @Test("Ruler adjustment is unavailable for an empty project")
    func rulerAdjustmentEmptyProject() {
        #expect(TimelineScrollMath.rulerAdjustmentTarget(
            currentTime: 0, totalDuration: 0, tickStep: 1, increment: true) == nil)
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
