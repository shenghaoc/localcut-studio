import Foundation
import CoreMedia

// MARK: - Replay buffer configuration

/// Configuration for the replay buffer ring.
public struct ReplayBufferConfig: Hashable, Sendable {
    public static let defaultMaxMemoryBytes = 256 * 1024 * 1024

    /// Maximum duration of buffered content in seconds.
    public var maxDurationSeconds: Double
    /// Maximum resident encoded bytes before old GOPs spill to disk.
    public var maxMemoryBytes: Int
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
                durationOption: DurationOption = .seconds30,
                maxMemoryBytes: Int = Self.defaultMaxMemoryBytes) {
        self.maxDurationSeconds = maxDurationSeconds ?? Double(durationOption.rawValue)
        self.maxMemoryBytes = max(1, maxMemoryBytes)
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
    /// Resident encoded-byte estimate after spill enforcement.
    public var residentMemoryBytes: Int
    /// Maximum configured resident-byte budget.
    public var maxMemoryBytes: Int
    /// Number of chunks whose metadata has been spilled from the resident set.
    public var spilledChunkCount: Int
    /// Bytes used by spill record files on disk.
    public var spillBytes: Int
    /// Number of distinct source files tracked.
    public var sourceCount: Int

    public init(chunkCount: Int = 0,
                bufferedDurationSeconds: Double = 0,
                maxDurationSeconds: Double = 30,
                residentMemoryBytes: Int = 0,
                maxMemoryBytes: Int = ReplayBufferConfig.defaultMaxMemoryBytes,
                spilledChunkCount: Int = 0,
                spillBytes: Int = 0,
                sourceCount: Int = 0) {
        self.chunkCount = chunkCount
        self.bufferedDurationSeconds = bufferedDurationSeconds
        self.maxDurationSeconds = maxDurationSeconds
        self.residentMemoryBytes = residentMemoryBytes
        self.maxMemoryBytes = maxMemoryBytes
        self.spilledChunkCount = spilledChunkCount
        self.spillBytes = spillBytes
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

    private enum ChunkStorage: Hashable, Sendable {
        case resident
        case spilled(URL, bytes: Int)
    }

    private struct StoredChunk: Hashable, Sendable {
        var chunk: EncodedChunk
        var storage: ChunkStorage
    }

    private struct SpillRecord: Encodable {
        var id: UUID
        var presentationTimeStamp: CodableTime
        var decodeTimeStamp: CodableTime
        var sourceTimeStamp: CodableTime
        var duration: CodableTime
        var byteSize: Int
        var isKeyframe: Bool
        var mediaType: EncodedChunkMediaType
        var sourceID: UUID
        var sourceFileURL: URL

        init(chunk: EncodedChunk) {
            id = chunk.id
            presentationTimeStamp = CodableTime(chunk.presentationTimeStamp)
            decodeTimeStamp = CodableTime(chunk.decodeTimeStamp)
            sourceTimeStamp = CodableTime(chunk.sourceTimeStamp)
            duration = CodableTime(chunk.duration)
            byteSize = chunk.byteSize
            isKeyframe = chunk.isKeyframe
            mediaType = chunk.mediaType
            sourceID = chunk.sourceID
            sourceFileURL = chunk.sourceFileURL
        }
    }

    private struct CodableTime: Encodable {
        var value: CMTimeValue
        var timescale: CMTimeScale
        var flags: UInt32
        var epoch: CMTimeEpoch

        init(_ time: CMTime) {
            value = time.value
            timescale = time.timescale
            flags = time.flags.rawValue
            epoch = time.epoch
        }
    }

    /// Ordered chunk index. Spilled entries stay in the index so saves can span
    /// resident and spilled metadata.
    private var entries: [StoredChunk] = []

    /// The ring's configuration.
    public private(set) var config: ReplayBufferConfig
    private let spillDirectory: URL?
    private var residentMemoryBytes = 0
    private var spillBytes = 0
    private var spillCounter = 0

    public init(config: ReplayBufferConfig = .default,
                spillDirectory: URL? = nil) {
        self.config = config
        self.spillDirectory = spillDirectory
    }

    // MARK: - Public interface

    /// Number of chunks currently in the ring.
    public var chunkCount: Int { entries.count }

    /// Whether the ring is empty.
    public var isEmpty: Bool { entries.isEmpty }

    /// All chunks in order.
    public var allChunks: [EncodedChunk] { entries.map(\.chunk) }

    /// Chunks whose encoded bytes still count against the resident budget.
    public var residentChunks: [EncodedChunk] {
        entries.compactMap { entry in
            if case .resident = entry.storage {
                return entry.chunk
            }
            return nil
        }
    }

    /// The time range covered by the ring buffer, if any.
    public var bufferedTimeRange: CMTimeRange? {
        guard let first = entries.first?.chunk, let last = entries.last?.chunk else { return nil }
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
        Set(entries.map { $0.chunk.sourceFileURL })
    }

    /// Updates the ring configuration. Triggers eviction if needed.
    public func updateConfig(_ newConfig: ReplayBufferConfig) {
        self.config = newConfig
        evictByDuration()
        enforceMemoryBudget()
    }

    /// Appends a chunk reference to the ring. Triggers duration eviction.
    public func append(_ chunk: EncodedChunk) {
        let entry = StoredChunk(chunk: chunk, storage: .resident)
        let insertIndex = entries.firstIndex {
            if $0.chunk.presentationTimeStamp == chunk.presentationTimeStamp {
                return $0.chunk.sourceID.uuidString > chunk.sourceID.uuidString
            }
            return $0.chunk.presentationTimeStamp > chunk.presentationTimeStamp
        } ?? entries.endIndex
        entries.insert(entry, at: insertIndex)
        residentMemoryBytes += max(0, chunk.byteSize)
        evictByDuration()
        enforceMemoryBudget()
    }

    /// Returns a diagnostics snapshot.
    public func diagnostics() -> ReplayBufferDiagnostics {
        ReplayBufferDiagnostics(
            chunkCount: entries.count,
            bufferedDurationSeconds: bufferedDurationSeconds,
            maxDurationSeconds: config.maxDurationSeconds,
            residentMemoryBytes: residentMemoryBytes,
            maxMemoryBytes: config.maxMemoryBytes,
            spilledChunkCount: spilledChunkCount,
            spillBytes: spillBytes,
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
        let chunks = allChunks
        guard !chunks.isEmpty else { return ([], 0) }

        let endTime = now ?? (chunks.last?.endTime ?? .zero)
        let boundaryTime = endTime - CMTime(seconds: seconds, preferredTimescale: 600)

        // Prefer video sync samples for decodable replay starts. Audio-only
        // recordings can start from an audio chunk boundary.
        let preferredMediaType: EncodedChunkMediaType = chunks.contains { $0.mediaType == .video }
            ? .video
            : .audio

        var startTime: CMTime?
        for i in stride(from: chunks.count - 1, through: 0, by: -1) {
            let chunk = chunks[i]
            if chunk.mediaType == preferredMediaType,
               chunk.isKeyframe,
               chunk.presentationTimeStamp <= boundaryTime {
                startTime = chunk.presentationTimeStamp
                break
            }
        }

        // If no keyframe sits that far back, use the earliest decodable chunk.
        if startTime == nil {
            startTime = chunks.first {
                $0.mediaType == preferredMediaType && $0.isKeyframe
            }?.presentationTimeStamp
        }

        guard let startTime else {
            return ([], 0)
        }

        let selected = chunks.filter { $0.endTime > startTime }
        guard let last = selected.last else { return ([], 0) }
        let actualDuration = last.endTime - startTime
        return (selected, max(0, actualDuration.seconds))
    }

    /// Removes all chunks.
    public func clear() {
        while !entries.isEmpty {
            removeEntry(at: 0)
        }
    }

    // MARK: - Eviction

    /// Evicts oldest chunks that exceed the duration cap, respecting
    /// keyframe boundaries.
    private func evictByDuration() {
        guard let last = entries.last?.chunk else { return }
        let cutoffTime = last.endTime - CMTime(seconds: config.maxDurationSeconds, preferredTimescale: 600)
        let chunks = allChunks

        // Keep from the latest video keyframe at or before the cutoff so a
        // full requested-duration save remains possible. Audio-only buffers can
        // evict directly at the cutoff.
        var keepStart: CMTime?
        for chunk in chunks where chunk.mediaType == .video && chunk.isKeyframe {
            if chunk.presentationTimeStamp <= cutoffTime {
                keepStart = chunk.presentationTimeStamp
            }
        }
        if keepStart == nil, !chunks.contains(where: { $0.mediaType == .video }) {
            keepStart = cutoffTime
        }
        guard let keepStart else { return }

        while let first = entries.first, first.chunk.endTime <= keepStart {
            removeEntry(at: 0)
        }
    }

    private var spilledChunkCount: Int {
        entries.reduce(0) { count, entry in
            if case .spilled = entry.storage {
                return count + 1
            }
            return count
        }
    }

    private func enforceMemoryBudget() {
        while residentMemoryBytes > config.maxMemoryBytes {
            guard spillOldestResidentSegment() else { break }
        }
    }

    @discardableResult
    private func spillOldestResidentSegment() -> Bool {
        guard let firstResidentIndex = entries.firstIndex(where: { entry in
            if case .resident = entry.storage { return true }
            return false
        }) else {
            return false
        }

        let firstTime = entries[firstResidentIndex].chunk.presentationTimeStamp
        let nextVideoKeyframeTime = entries.dropFirst(firstResidentIndex + 1)
            .map(\.chunk)
            .first {
                $0.mediaType == .video
                    && $0.isKeyframe
                    && $0.presentationTimeStamp > firstTime
            }?.presentationTimeStamp

        let candidateIndices: [Int]
        if let nextVideoKeyframeTime {
            candidateIndices = entries.indices.filter { index in
                guard index >= firstResidentIndex else { return false }
                guard case .resident = entries[index].storage else { return false }
                return entries[index].chunk.presentationTimeStamp < nextVideoKeyframeTime
            }
        } else {
            candidateIndices = [firstResidentIndex]
        }

        var didSpill = false
        for index in candidateIndices {
            guard index < entries.count else { continue }
            guard case .resident = entries[index].storage else { continue }
            let chunk = entries[index].chunk
            let recordBytes = writeSpillRecord(for: chunk)
            entries[index].storage = .spilled(
                spillURL(for: chunk),
                bytes: recordBytes)
            residentMemoryBytes = max(0, residentMemoryBytes - max(0, chunk.byteSize))
            spillBytes += recordBytes
            didSpill = true
        }
        return didSpill
    }

    private func writeSpillRecord(for chunk: EncodedChunk) -> Int {
        guard let spillDirectory else { return 0 }
        do {
            try FileManager.default.createDirectory(
                at: spillDirectory,
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SpillRecord(chunk: chunk))
            try data.write(to: spillURL(for: chunk), options: [.atomic])
            return data.count
        } catch {
            return 0
        }
    }

    private func spillURL(for chunk: EncodedChunk) -> URL {
        if let spillDirectory {
            return spillDirectory.appendingPathComponent("\(chunk.id.uuidString).json")
        }
        spillCounter += 1
        return URL(fileURLWithPath: "memory-spill-\(spillCounter).json")
    }

    private func removeEntry(at index: Int) {
        let entry = entries.remove(at: index)
        switch entry.storage {
        case .resident:
            residentMemoryBytes = max(0, residentMemoryBytes - max(0, entry.chunk.byteSize))
        case .spilled(let url, let bytes):
            spillBytes = max(0, spillBytes - bytes)
            if url.isFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
