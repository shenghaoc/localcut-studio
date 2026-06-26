import Testing
@testable import LocalCut_Studio

// Covers the @SceneStorage fallback logic in EditorSideRailView: a stored raw
// value that no longer maps to a case (e.g. a key written by an older layout)
// must resolve to a safe default rather than dropping the rail (Codex review).

@Suite("EditorSideRailView: persisted rail-selection fallback")
struct SideRailFallbackTests {

    @Test("RailGroup.resolve maps every known raw value to its case")
    func railGroupKnownValues() {
        #expect(RailGroup.resolve("inspector") == .inspector)
        #expect(RailGroup.resolve("audio") == .audio)
        #expect(RailGroup.resolve("captions") == .captions)
        #expect(RailGroup.resolve("tools") == .tools)
    }

    @Test("RailGroup.resolve falls back to .inspector for unknown / stale values")
    func railGroupFallback() {
        #expect(RailGroup.resolve("") == .inspector)
        #expect(RailGroup.resolve("sideRailPanel") == .inspector)   // abandoned legacy key value
        #expect(RailGroup.resolve("beats") == .inspector)           // a ToolPanel raw, not a group
    }

    @Test("ToolPanel.resolve maps every known raw value to its case")
    func toolPanelKnownValues() {
        #expect(ToolPanel.resolve("beats") == .beats)
        #expect(ToolPanel.resolve("renders") == .renders)
        #expect(ToolPanel.resolve("markers") == .markers)
    }

    @Test("ToolPanel.resolve falls back to .beats for unknown / stale values")
    func toolPanelFallback() {
        #expect(ToolPanel.resolve("") == .beats)
        #expect(ToolPanel.resolve("inspector") == .beats)           // a RailGroup raw, not a tool
    }

    // Lock the property the segmented picker depends on: every case must
    // produce a non-empty, unique localized title — no duplicate keys (which
    // would collapse cases in the rotor), no future `default:` arm returning
    // "". Catches the regression cheaply with no UI required (audit P3).
    @Test("RailGroup titles are unique and non-empty")
    func railGroupTitlesAreUniqueAndNonEmpty() {
        let titles = RailGroup.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }

    @Test("ToolPanel titles are unique and non-empty")
    func toolPanelTitlesAreUniqueAndNonEmpty() {
        let titles = ToolPanel.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }
}
