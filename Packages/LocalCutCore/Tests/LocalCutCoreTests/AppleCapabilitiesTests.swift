import Testing
import LocalCutDomain
import LocalCutCore

@Test("Apple capability snapshot is stable across repeated calls")
func capabilitiesCurrentStable() {
    let first = Capabilities.current
    let second = Capabilities.current
    #expect(first == second)
}

@Test("Apple capability snapshot reports a defined chip and OS")
func capabilitiesCurrentSane() {
    let capabilities = Capabilities.current
    switch capabilities.chip {
    case .intel:
        break
    case .appleSilicon(let generation):
        #expect(generation >= 0)
    }
    #expect(capabilities.osVersion.major > 0)
}

@Test("Apple capability snapshot returns a reason for every feature")
func capabilitiesReasonsNonEmpty() {
    let capabilities = Capabilities.current
    for feature in [
        CapabilityFeature.frameInterpolation,
        .simultaneousCaptureStreams(count: 1),
        .simultaneousCaptureStreams(count: 4),
        .metalEffectChain,
    ] {
        #expect(!capabilities.tier(for: feature).reason.isEmpty)
    }
}

@Test("Diagnostics bridge tracks the encoder budget")
func diagnosticsEncoderBudget() {
    let bridge = DiagnosticsBridge()
    bridge.setEncoderBudget(active: 2, max: 4, ledger: ["export", "programIso"])
    let snapshot = bridge.snapshot()
    #expect(snapshot.encoderLeaseCount == 2)
    #expect(snapshot.encoderBudgetMax == 4)
    #expect(snapshot.encoderLedger.count == 2)

    bridge.clearEncoderBudget()
    let cleared = bridge.snapshot()
    #expect(cleared.encoderLeaseCount == 0)
    #expect(cleared.encoderBudgetMax == 0)
    #expect(cleared.encoderLedger.isEmpty)
}
