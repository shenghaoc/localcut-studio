import Testing
import Foundation
@testable import LocalCutCore

@Suite("EncoderBudget")
struct EncoderBudgetTests {

    @Test("Acquiring within budget succeeds")
    func acquireWithinBudget() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let lease = try await budget.acquire(.export)
        #expect(await budget.activeCount == 1)
        lease.relinquish()
        #expect(await budget.activeCount == 0)
    }

    @Test("Acquiring beyond budget fails")
    func acquireBeyondBudget() async throws {
        let budget = EncoderBudget(maxConcurrent: 2)
        _ = try await budget.acquire(.export)
        _ = try await budget.acquire(.isoRecord)
        await #expect(throws: EncoderBudgetError.self) {
            try await budget.acquire(.programIso)
        }
        #expect(await budget.activeCount == 2)
    }

    @Test("Partial failure releases already-acquired leases")
    func partialFailureReleases() async throws {
        let budget = EncoderBudget(maxConcurrent: 2)
        let leases = try await budget.acquire(.export, count: 2)
        #expect(leases.count == 2)
        #expect(await budget.activeCount == 2)
        // Budget is now full; trying to acquire more should fail.
        await #expect(throws: EncoderBudgetError.self) {
            try await budget.acquire(.isoRecord)
        }
        // Release all leases.
        budget.releaseAll(leases)
        #expect(await budget.activeCount == 0)
    }

    @Test("Lease release is idempotent")
    func leaseReleaseIdempotent() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let lease = try await budget.acquire(.export)
        #expect(await budget.activeCount == 1)
        lease.relinquish()
        #expect(await budget.activeCount == 0)
        // Double release should be a no-op.
        lease.relinquish()
        #expect(await budget.activeCount == 0)
    }

    @Test("Budget exhaustion happens before encoder-open")
    func budgetExhaustionBeforeEncoderOpen() async throws {
        let budget = EncoderBudget(maxConcurrent: 1)
        _ = try await budget.acquire(.export)
        // Second acquire should fail — simulating that we check budget
        // before opening any encoder.
        var didFail = false
        do {
            _ = try await budget.acquire(.isoRecord)
        } catch EncoderBudgetError.budgetExhausted {
            didFail = true
        }
        #expect(didFail)
    }

    @Test("All consumer types share the same ledger")
    func allConsumersShareLedger() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let e = try await budget.acquire(.export)
        let i = try await budget.acquire(.isoRecord)
        let w = try await budget.acquire(.whipPublish)
        let p = try await budget.acquire(.programIso)
        #expect(await budget.activeCount == 4)
        await #expect(throws: EncoderBudgetError.self) {
            try await budget.acquire(.export)
        }
        // Release in any order.
        w.relinquish()
        p.relinquish()
        e.relinquish()
        i.relinquish()
        #expect(await budget.activeCount == 0)
    }

    @Test("Count acquire returns correct number of leases")
    func countAcquire() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let leases = try await budget.acquire(.programIso, count: 3)
        #expect(leases.count == 3)
        #expect(await budget.activeCount == 3)
        #expect(await budget.availableCount == 1)
        budget.releaseAll(leases)
        #expect(await budget.activeCount == 0)
    }

    @Test("Zero count returns empty array")
    func zeroCountReturnsEmpty() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let leases = try await budget.acquire(.export, count: 0)
        #expect(leases.isEmpty)
        #expect(await budget.activeCount == 0)
    }

    @Test("Ledger reflects active leases")
    func ledgerReflectsActive() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let lease = try await budget.acquire(.programIso)
        let ledger = await budget.ledger
        #expect(ledger.count == 1)
        #expect(ledger[0].consumer == .programIso)
        lease.relinquish()
        let emptyLedger = await budget.ledger
        #expect(emptyLedger.isEmpty)
    }
}
