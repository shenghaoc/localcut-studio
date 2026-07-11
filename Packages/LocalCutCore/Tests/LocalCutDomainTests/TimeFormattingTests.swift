import Testing
import LocalCutDomain

@Test("Time formatting clamps invalid values and rounds hundredths")
func timeFormattingClampAndRound() {
    #expect(TimeFormatting.timecode(.nan) == "0:00.00")
    #expect(TimeFormatting.timecode(-1) == "0:00.00")
    #expect(TimeFormatting.timecode(61.239) == "1:01.24")
    #expect(TimeFormatting.timecode(59.999) == "1:00.00")
    #expect(TimeFormatting.timecode(360_000) == "6000:00.00")
    #expect(TimeFormatting.timecode(360_000.01) == "0:00.00")
    #expect(TimeFormatting.timecode(1e17) == "0:00.00")
}
