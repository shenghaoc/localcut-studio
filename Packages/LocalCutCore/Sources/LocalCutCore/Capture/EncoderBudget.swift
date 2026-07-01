import Foundation
import VideoToolbox

// MARK: - Encoder consumer

/// Identifies a consumer of the shared encoder budget. Each consumer type
/// corresponds to a distinct use of a hardware video encoder session.
public enum EncoderConsumer: String, Hashable, Sendable, Codable {
    /// Timeline export (single-session).
    case export
    /// ISO recording of individual sources.
    case isoRecord
    /// WHIP streaming (Phase 47).
    case whipPublish
    /// Program Mode ISO recording (Phase 45).
    case programIso
}

// MARK: - Encoder lease

/// A token representing one acquired slot of the encoder budget. The lease
/// must be released exactly once; double-release is a no-op (guarded).
public struct EncoderLease: Sendable, Identifiable {
    public let id: UUID
    public let consumer: EncoderConsumer
    private let release: @Sendable () -> Void

    public init(id: UUID = UUID(),
                consumer: EncoderConsumer,
                release: @escaping @Sendable () -> Void) {
        self.id = id
        self.consumer = consumer
        self.release = release
    }

    /// Releases this lease. Safe to call multiple times — only the first
    /// call has any effect.
    public func relinquish() {
        release()
    }
}

// MARK: - Budget error

public enum EncoderBudgetError: Error, Sendable, Equatable {
    /// Acquiring the requested leases would exceed the budget.
    case budgetExhausted(requested: Int, available: Int)
}

// MARK: - EncoderBudget actor

/// Shared actor that gates concurrent hardware video encoder sessions.
/// Consumers acquire leases before opening encoders; on partial failure,
/// already-acquired leases are released.
///
/// The default budget is:
/// - 4 concurrent video sessions on hardware encode (enough for the
///   documented 2-cam + 1-screen multi-cam smoke test plus an export or
///   publish session).
/// - 1 concurrent video session on software-only.
///
/// Per-host probing can raise or lower the default at runtime.
public actor EncoderBudget {

    /// The ledger of currently held leases, keyed by lease ID.
    private var leases: [UUID: EncoderConsumer] = [:]

    /// The maximum number of concurrent video encoder sessions.
    public let maxConcurrent: Int

    /// Creates an encoder budget with the given maximum. If `maxConcurrent`
    /// is nil, the budget auto-probes from hardware capabilities.
    public init(maxConcurrent: Int? = nil) {
        if let explicit = maxConcurrent {
            self.maxConcurrent = max(1, explicit)
        } else {
            self.maxConcurrent = Self.probeDefaultBudget()
        }
    }

    /// Number of currently held leases.
    public var activeCount: Int { leases.count }

    /// Number of available lease slots.
    public var availableCount: Int { max(0, maxConcurrent - leases.count) }

    /// Whether the budget is fully exhausted.
    public var isExhausted: Bool { leases.count >= maxConcurrent }

    /// Current lease ledger for diagnostics. Returns an array of
    /// (consumer, leaseID) pairs.
    public var ledger: [(consumer: EncoderConsumer, leaseID: UUID)] {
        leases.map { (consumer: $0.value, leaseID: $0.key) }
    }

    /// Attempts to acquire `count` leases for the given consumer. Returns
    /// an array of leases on success, or throws `EncoderBudgetError` if
    /// the budget would be exceeded. On partial failure (should not happen
    /// with the atomic check, but provided for safety), already-acquired
    /// leases are released.
    public func acquire(_ consumer: EncoderConsumer,
                        count: Int = 1) throws -> [EncoderLease] {
        guard count > 0 else { return [] }
        guard leases.count + count <= maxConcurrent else {
            throw EncoderBudgetError.budgetExhausted(
                requested: count,
                available: maxConcurrent - leases.count)
        }
        var acquired: [EncoderLease] = []
        for _ in 0..<count {
            let lease = EncoderLease(consumer: consumer) { [weak self] in
                // The release closure captures self weakly; if the budget
                // actor is deallocated, the release is a no-op.
                Task { await self?.releaseLease(id: lease.id) }
            }
            leases[lease.id] = consumer
            acquired.append(lease)
        }
        return acquired
    }

    /// Convenience: acquires a single lease.
    public func acquire(_ consumer: EncoderConsumer) throws -> EncoderLease {
        let leases = try acquire(consumer, count: 1)
        guard let lease = leases.first else {
            // Should not happen with count=1 > 0, but defensive.
            throw EncoderBudgetError.budgetExhausted(requested: 1, available: availableCount)
        }
        return lease
    }

    /// Releases a lease by ID. Idempotent — releasing an already-released
    /// lease is a no-op.
    private func releaseLease(id: UUID) {
        leases.removeValue(forKey: id)
    }

    /// Releases all leases in the given array. Useful for cleanup on
    /// partial setup failure.
    public func releaseAll(_ leasesToRelease: [EncoderLease]) {
        for lease in leasesToRelease {
            leases.removeValue(forKey: lease.id)
        }
    }

    // MARK: - Probing

    /// Probes the default budget from hardware capabilities. Returns 4 if
    /// hardware encoders are available, 1 otherwise.
    private static func probeDefaultBudget() -> Int {
        let count = probeHardwareEncoderCount()
        return count > 0 ? 4 : 1
    }

    private static func probeHardwareEncoderCount() -> Int {
        var listRef: CFArray?
        let status = VTCopyVideoEncoderList(nil, &listRef)
        guard status == noErr, let list = listRef else { return 0 }
        let hwKey = kVTVideoEncoderList_IsHardwareAccelerated as String
        var hwCount = 0
        for entry in (list as NSArray) {
            guard let dict = entry as? [String: Any] else { continue }
            if (dict[hwKey] as? Bool) == true { hwCount += 1 }
        }
        return hwCount
    }
}
