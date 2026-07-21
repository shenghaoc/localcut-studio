import Foundation
import LocalCutCore

/// Lifecycle states a queue job moves through. The state machine is monotone
/// for terminal states — `completed` / `cancelled` / `failed` are never
/// re-entered.
nonisolated enum QueueJobStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case cancelled
    case failed

    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

nonisolated enum QueueEnqueueOutcome: Equatable, Sendable {
    case queued
    case failed(String)
}

/// One render job: the recipe (`preset`) + where to write it
/// (`outputBookmark`) + a frozen project snapshot the runner expands into an
/// `AVComposition` at job-start.
///
/// The job is the persistence unit — every field round-trips through
/// `RenderQueueDoc`. The `projectSnapshot` field reuses `ProjectDocument`
/// rather than introducing a parallel snapshot type so the queue inherits the
/// document model's existing schema-versioning + lenient decoding.
///
/// Implicitly MainActor (no `nonisolated` marker) to match the surrounding
/// document model — `ProjectDocument`'s Codable methods are MainActor, so
/// `QueueJob.init(from:)` has to be MainActor too to nest the decode.
/// MainActor structs are Sendable in Swift 6, so cross-task passing still
/// compiles. Equatable rather than Hashable because `ProjectDocument` is only
/// Equatable; nothing in the queue needs a `Set<QueueJob>`.
struct QueueJob: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var preset: ExportPreset
    /// Security-scoped bookmark to the selected output file. Older jobs may
    /// carry a destination-directory bookmark; resolution handles both shapes
    /// so queued renders survive upgrades and retries.
    var outputBookmark: Data
    /// Display filename for the inspector list and the leaf name appended when
    /// `outputBookmark` resolves to a directory URL.
    var outputDisplayName: String
    var projectSnapshot: ProjectDocument
    var status: QueueJobStatus
    var progress: Double
    var errorMessage: String?
    /// Wall-clock seconds the job spent in `.running` before its terminal
    /// status. Persisted so the inspector can show "completed in 12.3 s"
    /// across relaunches.
    var runtimeSeconds: Double?
    /// New Save-panel files are reserved before their file bookmark is encoded.
    /// Optional keeps persisted jobs from older builds source-compatible.
    var outputReservationCreated: Bool?
    /// Set when the saved destination cannot safely be reused. This stays
    /// optional so older persisted queue documents decode as retryable.
    private(set) var retryUnavailable: Bool?
    /// Set as soon as encoding leaves a complete movie at the output URL and
    /// retained if later post-work fails. Normal completion clears it; crash
    /// recovery uses it to avoid requeueing over the finished movie.
    private(set) var completedOutputPreserved: Bool?
    /// Set before the runner removes the selected file/reservation and begins
    /// writing. If the process exits mid-run, the destination may contain the
    /// user's prior file, a partial encode, or a complete movie, so recovery
    /// must leave it untouched instead of automatically requeueing the job.
    private(set) var outputWriteStarted: Bool?

    init(id: UUID = UUID(),
         preset: ExportPreset,
         outputBookmark: Data,
         outputDisplayName: String,
         projectSnapshot: ProjectDocument,
         status: QueueJobStatus = .queued,
         progress: Double = 0,
         errorMessage: String? = nil,
         runtimeSeconds: Double? = nil,
         outputReservationCreated: Bool = false,
         destinationProtection: DestinationProtection = .reusable) {
        self.id = id
        self.preset = preset
        self.outputBookmark = outputBookmark
        self.outputDisplayName = outputDisplayName
        self.projectSnapshot = projectSnapshot
        self.status = status
        self.progress = progress
        self.errorMessage = errorMessage
        self.runtimeSeconds = runtimeSeconds
        self.outputReservationCreated = outputReservationCreated ? true : nil
        self.retryUnavailable = nil
        self.completedOutputPreserved = nil
        self.outputWriteStarted = nil
        applyDestinationProtection(destinationProtection)
    }

    var isTerminal: Bool {
        switch status {
        case .completed, .cancelled, .failed: true
        case .queued, .running: false
        }
    }

    /// Coalesces the optional destination flags into one policy value so
    /// callers reason about states, not independent bool combinations.
    /// On-disk JSON still stores the optional flags for older builds.
    enum DestinationProtection: Equatable, Sendable {
        /// Destination may be reused by Retry / auto-requeue.
        case reusable
        /// Encoding took ownership of the leaf; crash recovery must not requeue.
        case writeStarted
        /// A complete movie is at the destination (post-export failure path).
        case completedPreserved
        /// Bookmark/reservation cannot be recreated; user must pick a new path.
        case permanentlyUnavailable
    }

    /// Derived destination safety. Precedence matches crash-recovery needs:
    /// preserved movie and permanent failure outrank a mid-write flag.
    var destinationProtection: DestinationProtection {
        if completedOutputPreserved == true { return .completedPreserved }
        if retryUnavailable == true { return .permanentlyUnavailable }
        if outputWriteStarted == true { return .writeStarted }
        return .reusable
    }

    /// A row can only reuse its saved destination when protection is `.reusable`.
    var canRetry: Bool { destinationProtection == .reusable }

    /// Applies one canonical protection state to the persisted optional flags.
    mutating func applyDestinationProtection(_ protection: DestinationProtection) {
        switch protection {
        case .reusable:
            retryUnavailable = nil
            completedOutputPreserved = nil
            outputWriteStarted = nil
        case .writeStarted:
            outputReservationCreated = nil
            retryUnavailable = nil
            completedOutputPreserved = nil
            outputWriteStarted = true
        case .completedPreserved:
            outputReservationCreated = nil
            retryUnavailable = true
            completedOutputPreserved = true
            outputWriteStarted = true
        case .permanentlyUnavailable:
            outputReservationCreated = nil
            retryUnavailable = true
            completedOutputPreserved = nil
            outputWriteStarted = nil
        }
    }
}

/// Versioned on-disk shape for the queue. A build that opens a newer-version
/// file refuses to overwrite it, matching `ProjectDocument`'s schema-version
/// guard. Implicitly MainActor for the same nested-decode reason as
/// `QueueJob`.
struct RenderQueueDoc: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var jobs: [QueueJob]

    init(version: Int = RenderQueueDoc.currentVersion, jobs: [QueueJob]) {
        self.version = version
        self.jobs = jobs
    }

    private enum CodingKeys: String, CodingKey { case version, jobs }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? RenderQueueDoc.currentVersion
        jobs = try c.decodeIfPresent([QueueJob].self, forKey: .jobs) ?? []
    }
}

/// Errors surfaced from the run loop. `errorDescription` populates the
/// inspector status pill via `QueueJob.errorMessage`.
nonisolated enum RenderQueueError: Error, LocalizedError {
    case unsupportedCombination(container: String, codec: String)
    case hostNotCapable(String)
    case outputDestinationUnavailable
    case compositionEmpty
    case chapterValidationFailed(String)
    case chapterSidecarWriteFailed(String)
    case exportSessionCreationFailed
    case writerInitializationFailed(String)
    case outputProtectionPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedCombination(let container, let codec):
            "Container \(container) does not support codec \(codec)."
        case .hostNotCapable(let reason):
            reason
        case .outputDestinationUnavailable:
            "Output destination unavailable."
        case .compositionEmpty:
            "Nothing to export — the project's timeline is empty."
        case .chapterValidationFailed(let detail):
            "Fix chapter markers before export: \(detail)"
        case .chapterSidecarWriteFailed(let detail):
            "Chapter sidecar was not written: \(detail)"
        case .exportSessionCreationFailed:
            "Could not create an export session for this preset."
        case .writerInitializationFailed(let detail):
            "Could not start the writer: \(detail)"
        case .outputProtectionPersistenceFailed:
            "Render queue protection could not be saved, so the output was left unchanged."
        }
    }
}
