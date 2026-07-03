import Foundation
import CoreMedia

// MARK: - Replay buffer configuration

/// Configuration for the replay buffer ring.
public struct ReplayBufferConfig: Hashable, Sendable {
    /// Maximum duration of buffered content in seconds.
    public var maxDurationSeconds: Double
    /// Duration option for UI display.
    public var durationOption: DurationOption

    public enum DurationOption: Int, Hashable, Sendable, CaseIterable, Identifiable {
        case seconds30 = 30
        case seconds60 = 60
        case seconds300 = 300

        public var id: Int { rawValue }
        public var displayName: String {
            switch self {
            case .seconds30: "30 seconds"
            case .seconds60: "60 seconds"
            case .seconds300: "5 minutes"
            }
        }
    }

    public init(maxDurationSeconds: Double? = nil,
                durationOption: DurationOption = .seconds30) {
        self.maxDurationSeconds = maxDurationSeconds ?? Double(durationOption.rawValue)
        self.durationOption = durationOption
    }

    /// Default configuration: 30 seconds.
    public static let `default` = ReplayBufferConfig()
}

// MARK: - Diagnostics snapshot

/// A point-in-time snapshot of the ring buffer's state for diagnostics display.
public struct ReplayBufferDiagnostics: Hashable, Sendable {
    /// Number of chunks in the ring.
    public var chunkCount: Int
    /// Total buffered duration in seconds.
    public var bufferedDurationSeconds: Double
    /// Maximum configured duration.
    public var maxDurationSeconds: Double
    /// Number of distinct source files tracked.
    public var sourceCount: Int

    public init(chunkCount: Int = 0,
                bufferedDurationSeconds: Double = 0,
                maxDurationSeconds: Double = 30,
                sourceCount: Int = 0) {
        self.chunkCount = chunkCount
        self.bufferedDurationSeconds = bufferedDurationSeconds
        self.maxDurationSeconds = maxDurationSeconds
        self.sourceCount = sourceCount
    }
}

// MARK: - EncodedChunkRing actor

/// A concurrency-safe ring buffer of encoded chunk references with duration
/// cap and keyframe-aligned eviction.
///
/// The ring holds chunk metadata (timestamps, source file URLs) but does NOT
/// store raw encoded bytes. The finalizer reads from the source files on demand
/// using AVAssetReader, which produces valid `.mov` output with proper headers.
public actor EncodedChunkRing {

    /// Ordered list of chunk references.
    private var chunks: [EncodedChunk] = []

    /// The ring's configuration.
    public private(set) var config: ReplayBufferConfig

    public init(config: ReplayBufferConfig = .default) {
        self.config = config
    }

    // MARK: - Public interface

    /// Number of chunks currently in the ring.
    public var chunkCount: Int { chunks.count }

    /// Whether the ring is empty.
    public var isEmpty: Bool { chunks.isEmpty }

    /// All chunks in order.
    public var allChunks: [EncodedChunk] { chunks }

    /// The time range covered by the ring buffer, if any.
    public var bufferedTimeRange: CMTimeRange? {
        guard let first = chunks.first, let last = chunks.last else { return nil }
        return CMTimeRange(
            start: first.presentationTimeStamp,
            end: last.endTime)
    }

    /// Total buffered duration in seconds.
    public var bufferedDurationSeconds: Double {
        guard let range = bufferedTimeRange else { return 0 }
        return range.duration.seconds
    }

    /// Distinct source file URLs in the ring.
    public var sourceFileURLs: Set<URL> {
        Set(chunks.map { $0.sourceFileURL })
    }

    /// Updates the ring configuration. Triggers eviction if needed.
    public func updateConfig(_ newConfig: ReplayBufferConfig) {
        self.config = newConfig
        evictByDuration()
    }

    /// Appends a chunk reference to the ring. Triggers duration eviction.
    public func append(_ chunk: EncodedChunk) {
        chunks.append(chunk)
        evictByDuration()
    }

    /// Returns a diagnostics snapshot.
    public func diagnostics() -> ReplayBufferDiagnostics {
        ReplayBufferDiagnostics(
            chunkCount: chunks.count,
            bufferedDurationSeconds: bufferedDurationSeconds,
            maxDurationSeconds: config.maxDurationSeconds,
            sourceCount: sourceFileURLs.count)
    }

    /// Selects a keyframe-aligned span for "save last N seconds".
    ///
    /// Finds the **latest keyframe at or before** `now - N` and returns all
    /// chunks from that keyframe to the end of the buffer. If no keyframe
    /// sits that far back, returns all available chunks from the earliest
    /// keyframe.
    public func selectSaveSpan(seconds: Double,
                               now: CMTime? = nil) -> (chunks: [EncodedChunk], actualSeconds: Double) {
        guard !chunks.isEmpty else { return ([], 0) }

        let endTime = now ?? (chunks.last?.endTime ?? .zero)
        let boundaryTime = endTime - CMTime(seconds: seconds, preferredTimescale: 600)

        // Find the latest keyframe at or before the boundary.
        var startIdx: Int?
        for i in stride(from: chunks.count - 1, through: 0, by: -1) {
            if chunks[i].isKeyframe && chunks[i].presentationTimeStamp <= boundaryTime {
                startIdx = i
                break
            }
        }

        // If no keyframe that far back, use the earliest keyframe available.
        if startIdx == nil {
            startIdx = chunks.firstIndex { $0.isKeyframe }
        }

        guard let idx = startIdx else {
            return ([], 0)
        }

        let selected = Array(chunks[idx...])
        let actualDuration = selected.last!.endTime - selected.first!.presentationTimeStamp
        return (selected, max(0, actualDuration.seconds))
    }

    /// Removes all chunks.
    public func clear() {
        chunks.removeAll()
    }

    // MARK: - Eviction

    /// Evicts oldest chunks that exceed the duration cap, respecting
    /// keyframe boundaries.
    private func evictByDuration() {
        guard let last = chunks.last else { return }
        let cutoffTime = last.endTime - CMTime(seconds: config.maxDurationSeconds, preferredTimescale: 600)

        // Find the latest keyframe at or before the cutoff.
        var lastKeyframeBeforeCutoff: Int?
        for i in 0..<chunks.count {
            if chunks[i].isKeyframe && chunks[i].presentationTimeStamp <= cutoffTime {
                lastKeyframeBeforeCutoff = i
            }
        }
        guard let kfIdx = lastKeyframeBeforeCutoff else { return }

        // Find the next keyframe after the cutoff keyframe.
        let afterKF = chunks.index(after: kfIdx)
        let nextKFIdx = chunks[afterKF...].firstIndex { $0.isKeyframe }
            ?? chunks.count

        guard nextKFIdx > 0 else { return }
        chunks.removeFirst(nextKFIdx)
    }
}
