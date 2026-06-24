import Testing
import AVFoundation
import LocalCutCore
@testable import LocalCut_Studio

@Suite("Caption Tail Filler")
struct CaptionTailFillerTests {

    @Test("Cached filler usability across durations and tolerances", arguments: [
        // Zero-duration cache is never usable, regardless of what's needed.
        (cached: CMTime.zero, needed: 0.0, usable: false),
        (cached: CMTime.zero, needed: 0.0005, usable: false),
        // A 1 s cache satisfies anything up to ~1 s (with tolerance) but not beyond.
        (cached: CMTime(seconds: 1, preferredTimescale: 600), needed: 0.0, usable: true),
        (cached: CMTime(seconds: 1, preferredTimescale: 600), needed: 1.0005, usable: true),
        (cached: CMTime(seconds: 1, preferredTimescale: 600), needed: 1.002, usable: false),
    ])
    func cachedDurationUsability(_ testCase: (cached: CMTime, needed: Double, usable: Bool)) {
        #expect(
            CaptionTailFiller.isCachedDurationUsable(testCase.cached, neededSeconds: testCase.needed)
            == testCase.usable
        )
    }

    @Test("Sanitized corrupt durations are rejected as unusable cache entries", arguments: [
        CMTime.indefinite.sanitized,
        CMTime(value: -1, timescale: 600).sanitized,
    ])
    func rejectsSanitizedCorruptDurations(_ corrupt: CMTime) {
        #expect(!CaptionTailFiller.isCachedDurationUsable(corrupt, neededSeconds: 0))
    }
}
