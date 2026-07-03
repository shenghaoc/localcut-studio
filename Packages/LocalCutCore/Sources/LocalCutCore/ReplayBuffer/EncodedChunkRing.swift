import Foundation
import CoreMedia

// MARK: - Replay buffer configuration

/// Configuration for the replay buffer ring.
public struct ReplayBufferConfig: Hashable, Sendable {
    /// Maximum in-memory bytes for the ring buffer.
    public var memoryBudgetBytes: Int
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

    public init(memoryBudgetBytes: Int = 256 * 1024 * 1024,
                maxDurationSeconds: Double? = nil,
                durationOption: DurationOption = .seconds30) {
        self.memoryBudgetBytes = memoryBudgetBytes
        self.maxDurationSeconds = maxDurationSeconds ?? Double(durationOption.rawValue)
        self.durationOption = durationOption
    }

    /// Default configuration: 256 MiB memory, 30 seconds.
    public static let `default` = ReplayBufferConfig()
}

// MARK: - Diagnostics snapshot

/// A point-in-time snapshot of the ring buffer's state for diagnostics display.
public struct ReplayBufferDiagnostics: Hashable, Sendable {
    /// Bytes currently held in memory.
    public var memoryUsedBytes: Int
    /// Configured memory budget.
    public var memoryBudgetBytes: Int
    /// Bytes spilled to disk.
    public var spillUsedBytes: Int
    /// Number of chunks in memory.
    public var inMemoryChunkCount: Int
    /// Number of chunks spilled to disk.
    public var spilledChunkCount: Int
    /// Total duration of buffered content in seconds.
    public var bufferedDurationSeconds: Double
    /// Maximum configured duration.
    public var maxDurationSeconds: Double
    /// Whether the buffer is under memory pressure.
    public var isUnderPressure: Bool

    public init(memoryUsedBytes: Int = 0,
                memoryBudgetBytes: Int = 256 * 1024 * 1024,
                spillUsedBytes: Int = 0,
                inMemoryChunkCount: Int = 0,
                spilledChunkCount: Int = 0,
                bufferedDurationSeconds: Double = 0,
                maxDurationSeconds: Double = 30,
                isUnderPressure: Bool = false) {
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryBudgetBytes = memoryBudgetBytes
        self.spillUsedBytes = spillUsedBytes
        self.inMemoryChunkCount = inMemoryChunkCount
        self.spilledChunkCount = spilledChunkCount
        self.bufferedDurationSeconds = bufferedDurationSeconds
        self.maxDurationSeconds = maxDurationSeconds
        self.isUnderPressure = isUnderPressure
    }
}

// MARK: - EncodedChunkRing actor

/// A concurrency-safe ring buffer of encoded video/audio chunks with memory
/// budget enforcement, duration cap, and keyframe-aligned eviction.
///
/// The ring holds recent encoded chunks in memory, spilling oldest
/// keyframe-aligned GOPs to disk when the memory budget would be exceeded.
/// A unified index spans both in-memory and spilled chunks so "save last N
/// seconds" can read across the boundary.
public actor EncodedChunkRing {

    /// Ordered list of chunks (both in-memory and spilled).
    private var chunks: [EncodedChunk] = []

    /// The ring's configuration.
    public private(set) var config: ReplayBufferConfig

    /// Total bytes currently held in memory across all in-memory chunks.
    private var memoryUsedBytes: Int = 0

    /// Total bytes spilled to disk.
    private var spillUsedBytes: Int = 0

    /// The base directory for spill files.
    private let spillDirectory: URL

    /// Whether spilling is active (directory was created successfully).
    private var spillActive: Bool = false

    public init(config: ReplayBufferConfig = .default,
                spillDirectory: URL? = nil) {
        self.config = config
        if let explicit = spillDirectory {
            self.spillDirectory = explicit
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.spillDirectory = caches
                .appendingPathComponent("ReplayBuffer", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        }
    }

    // MARK: - Public interface

    /// Number of chunks currently in the ring (memory + spilled).
    public var chunkCount: Int { chunks.count }

    /// Whether the ring is empty.
    public var isEmpty: Bool { chunks.isEmpty }

    /// All chunks in order (unified index).
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

    /// Updates the ring configuration. Triggers eviction if needed.
    public func updateConfig(_ newConfig: ReplayBufferConfig) {
        self.config = newConfig
        evictExcess()
    }

    /// Appends a chunk to the ring. Triggers eviction if memory budget or
    /// duration cap would be exceeded.
    public func append(_ chunk: EncodedChunk) {
        chunks.append(chunk)
        memoryUsedBytes += chunk.memoryBytes
        evictExcess()
    }

    /// Appends a chunk, spilling oldest keyframe-aligned spans if needed.
    /// Returns the number of chunks evicted/spilled.
    @discardableResult
    public func appendWithSpill(_ chunk: EncodedChunk,
                                spillIfNeeded: Bool = true) -> Int {
        chunks.append(chunk)
        memoryUsedBytes += chunk.memoryBytes
        return evictExcessWithSpill(spillIfNeeded: spillIfNeeded)
    }

    /// Returns a diagnostics snapshot.
    public func diagnostics() -> ReplayBufferDiagnostics {
        ReplayBufferDiagnostics(
            memoryUsedBytes: memoryUsedBytes,
            memoryBudgetBytes: config.memoryBudgetBytes,
            spillUsedBytes: spillUsedBytes,
            inMemoryChunkCount: chunks.filter { $0.isInMemory }.count,
            spilledChunkCount: chunks.filter { $0.isSpilled }.count,
            bufferedDurationSeconds: bufferedDurationSeconds,
            maxDurationSeconds: config.maxDurationSeconds,
            isUnderPressure: memoryUsedBytes > config.memoryBudgetBytes)
    }

    /// Selects a keyframe-aligned span for "save last N seconds".
    ///
    /// Finds the **latest keyframe at or before** `now - N` and returns all
    /// chunks from that keyframe to the end of the buffer. If no keyframe
    /// sits that far back, returns all available chunks from the earliest
    /// keyframe.
    ///
    /// - Parameters:
    ///   - seconds: The requested save duration in seconds.
    ///   - now: The current time (end of the buffer).
    /// - Returns: The selected chunks and the actual saved duration.
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

    /// Loads data for a spilled chunk back into memory. Returns the updated
    /// chunk, or nil if the chunk is already in memory or not found.
    public func loadSpilledChunk(id: UUID) -> EncodedChunk? {
        guard let idx = chunks.firstIndex(where: { $0.id == id }),
              chunks[idx].isSpilled else { return nil }
        do {
            try chunks[idx].loadDataFromSpill()
            if let data = chunks[idx].data {
                memoryUsedBytes += data.count
            }
            return chunks[idx]
        } catch {
            return nil
        }
    }

    /// Ensures all chunks in the given span have data loaded. Returns the
    /// chunks with data populated, or an empty array if any chunk fails to
    /// load. Reads spill data into returned copies without mutating the
    /// ring's memory accounting (the caller is responsible for the data
    /// lifetime during finalization).
    public func loadChunksForSave(_ span: [EncodedChunk]) -> [EncodedChunk] {
        var result: [EncodedChunk] = []
        result.reserveCapacity(span.count)
        for chunk in span {
            var c = chunk
            if c.isSpilled && !c.isInMemory {
                // Read spill data directly into the copy without mutating
                // the ring's internal state. This avoids inflating
                // memoryUsedBytes for transient save operations.
                guard let url = c.spillURL,
                      let data = try? Data(contentsOf: url) else { return [] }
                c = EncodedChunk(
                    id: c.id,
                    presentationTimeStamp: c.presentationTimeStamp,
                    decodeTimeStamp: c.decodeTimeStamp,
                    duration: c.duration,
                    byteSize: c.byteSize,
                    isKeyframe: c.isKeyframe,
                    sourceID: c.sourceID,
                    data: data)
            }
            guard c.data != nil else { return [] }
            result.append(c)
        }
        return result
    }

    /// Removes all chunks and cleans up spill files.
    public func clear() {
        cleanupSpillFiles()
        chunks.removeAll()
        memoryUsedBytes = 0
        spillUsedBytes = 0
    }

    /// Ensures spill directory exists. Call once at session start.
    public func prepareSpillDirectory() throws {
        try FileManager.default.createDirectory(
            at: spillDirectory,
            withIntermediateDirectories: true)
        spillActive = true
    }

    /// Returns the spill directory URL.
    public var spillDirectoryURL: URL { spillDirectory }

    // MARK: - Eviction

    /// Evicts chunks to respect memory budget and duration cap. Returns the
    /// number of chunks removed.
    @discardableResult
    private func evictExcessWithSpill(spillIfNeeded: Bool) -> Int {
        var evicted = 0

        // First, enforce duration cap by removing oldest chunks.
        evicted += evictByDuration()

        // Then, enforce memory budget by spilling oldest keyframe-aligned spans.
        if spillIfNeeded && spillActive {
            evicted += evictByMemoryWithSpill()
        } else {
            evicted += evictByMemoryDrop()
        }

        return evicted
    }

    /// Evicts oldest chunks that exceed the duration cap, respecting
    /// keyframe boundaries. Also cleans up spill files for spilled chunks.
    private func evictByDuration() -> Int {
        guard let last = chunks.last else { return 0 }
        let cutoffTime = last.endTime - CMTime(seconds: config.maxDurationSeconds, preferredTimescale: 600)

        // Find the latest keyframe at or before the cutoff. Evict everything
        // up to (but not including) the NEXT keyframe after it, so the ring
        // always starts at a keyframe boundary.
        var lastKeyframeBeforeCutoff: Int?
        for i in 0..<chunks.count {
            if chunks[i].isKeyframe && chunks[i].presentationTimeStamp <= cutoffTime {
                lastKeyframeBeforeCutoff = i
            }
        }
        guard let kfIdx = lastKeyframeBeforeCutoff else { return 0 }

        // Find the next keyframe after the cutoff keyframe.
        let afterKF = chunks.index(after: kfIdx)
        let nextKFIdx = chunks[afterKF...].firstIndex { $0.isKeyframe }
            ?? chunks.count

        guard nextKFIdx > 0 else { return 0 }

        // Clean up spill files for spilled chunks being evicted.
        for i in 0..<nextKFIdx {
            if let spillURL = chunks[i].spillURL {
                try? FileManager.default.removeItem(at: spillURL)
                spillUsedBytes -= chunks[i].byteSize
            }
            memoryUsedBytes -= chunks[i].memoryBytes
        }
        chunks.removeFirst(nextKFIdx)
        return nextKFIdx
    }

    /// Spills oldest keyframe-aligned spans to disk until memory budget is met.
    private func evictByMemoryWithSpill() -> Int {
        var evicted = 0

        while memoryUsedBytes > config.memoryBudgetBytes, !chunks.isEmpty {
            // Find the first keyframe in the buffer.
            guard let firstKFIdx = chunks.firstIndex(where: { $0.isKeyframe && $0.isInMemory }) else {
                break
            }

            // Evict from the start of the buffer up to (not including) the
            // next keyframe. This removes any pre-keyframe frames and the
            // first keyframe's GOP, ensuring the buffer always starts at a
            // keyframe boundary.
            let afterFirstKF = chunks.index(after: firstKFIdx)
            let nextKFIdx = chunks[afterFirstKF...].firstIndex { $0.isKeyframe }
                ?? chunks.count

            // Spill all chunks in this span.
            var spillFailed = false
            for i in 0..<nextKFIdx {
                guard chunks[i].isInMemory else { continue }
                do {
                    let fileURL = spillDirectory.appendingPathComponent("\(chunks[i].id.uuidString).chunk")
                    if let data = chunks[i].data {
                        try data.write(to: fileURL)
                        spillUsedBytes += data.count
                        memoryUsedBytes -= data.count
                        chunks[i].clearMemoryData()
                        chunks[i].spillURL = fileURL
                        evicted += 1
                    }
                } catch {
                    // If spill fails, stop evicting — we'll be over budget
                    // but won't lose data or spin forever.
                    spillFailed = true
                    break
                }
            }
            if spillFailed { break }
        }

        return evicted
    }

    /// Drops oldest chunks entirely (no spill) when memory budget is exceeded.
    private func evictByMemoryDrop() -> Int {
        var evicted = 0

        while memoryUsedBytes > config.memoryBudgetBytes, !chunks.isEmpty {
            // Find the first keyframe.
            guard let firstKFIdx = chunks.firstIndex(where: { $0.isKeyframe }) else {
                // No keyframes — drop everything.
                let removed = chunks
                for chunk in removed { memoryUsedBytes -= chunk.memoryBytes }
                chunks.removeAll()
                return removed.count
            }

            // Drop from start up to the next keyframe.
            let afterFirstKF = chunks.index(after: firstKFIdx)
            let nextKFIdx = chunks[afterFirstKF...].firstIndex { $0.isKeyframe }
                ?? chunks.count

            for i in 0..<nextKFIdx {
                memoryUsedBytes -= chunks[i].memoryBytes
            }
            chunks.removeFirst(nextKFIdx)
            evicted += nextKFIdx
        }

        return evicted
    }

    /// Simple eviction (no spill) for backward compatibility.
    private func evictExcess() {
        _ = evictByDuration()
        _ = evictByMemoryDrop()
    }

    /// Cleans up spill files for this session.
    private func cleanupSpillFiles() {
        guard spillActive else { return }
        try? FileManager.default.removeItem(at: spillDirectory)
    }

    deinit {
        // Note: deinit is not called on actors in all cases. Explicit cleanup
        // via clear() is preferred.
    }
}
