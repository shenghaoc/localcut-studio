import Testing
import AVFoundation
@testable import LocalCut_Studio

@Suite("Caption Tail Filler")
struct CaptionTailFillerTests {

    @Test("Zero-duration cached filler is never reused")
    func rejectsZeroDurationCache() {
        #expect(!CaptionTailFiller.isCachedDurationUsable(.zero, neededSeconds: 0))
        #expect(!CaptionTailFiller.isCachedDurationUsable(.zero, neededSeconds: 0.0005))
    }

    @Test("Sanitized corrupt durations are rejected as unusable cache entries")
    func rejectsSanitizedCorruptDurations() {
        #expect(!CaptionTailFiller.isCachedDurationUsable(.indefinite.sanitized, neededSeconds: 0))
        #expect(!CaptionTailFiller.isCachedDurationUsable(CMTime(value: -1, timescale: 600).sanitized,
                                                         neededSeconds: 0))
    }

    @Test("Positive cached filler can satisfy the requested duration")
    func acceptsPositiveCacheWithTolerance() {
        let cachedDuration = CMTime(seconds: 1, preferredTimescale: 600)

        #expect(CaptionTailFiller.isCachedDurationUsable(cachedDuration, neededSeconds: 0))
        #expect(CaptionTailFiller.isCachedDurationUsable(cachedDuration, neededSeconds: 1.0005))
        #expect(!CaptionTailFiller.isCachedDurationUsable(cachedDuration, neededSeconds: 1.002))
    }
}
