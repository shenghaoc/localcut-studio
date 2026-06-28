import Foundation
import CoreMedia

public enum CaptureSourceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case display
    case window
    case application
    case webcam
    case microphone
    case systemAudio

    public var isVideo: Bool {
        switch self {
        case .display, .window, .application, .webcam: true
        case .microphone, .systemAudio: false
        }
    }
}

public struct CaptureSourceDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var kind: CaptureSourceKind
    public var displayName: String
    public var relativePath: String
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var sampleRate: Double?
    public var channels: Int?
    public var timelineStartUs: Int64

    public init(id: UUID = UUID(),
                kind: CaptureSourceKind,
                displayName: String,
                relativePath: String,
                width: Int? = nil,
                height: Int? = nil,
                frameRate: Double? = nil,
                sampleRate: Double? = nil,
                channels: Int? = nil,
                timelineStartUs: Int64 = 0) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.relativePath = relativePath
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.sampleRate = sampleRate
        self.channels = channels
        self.timelineStartUs = max(0, timelineStartUs)
    }

    public var timelineStart: CMTime {
        CMTime(value: timelineStartUs, timescale: CaptureManifest.microsecondTimescale)
    }
}

public struct CaptureEncoderConfig: Codable, Hashable, Sendable {
    public var fileType: String
    public var codec: String
    public var bitrate: Int
    public var fragmentIntervalUs: Int64
    public var realTime: Bool

    public init(fileType: String = "mov",
                codec: String,
                bitrate: Int,
                fragmentIntervalUs: Int64,
                realTime: Bool = true) {
        self.fileType = fileType
        self.codec = codec
        self.bitrate = bitrate
        self.fragmentIntervalUs = fragmentIntervalUs
        self.realTime = realTime
    }
}

public struct CaptureManifestHeader: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var sessionID: UUID
    public var createdAt: Date
    public var sessionStartHostTimeUs: Int64
    public var sources: [CaptureSourceDescriptor]
    public var encoders: [UUID: CaptureEncoderConfig]

    public init(schemaVersion: Int = CaptureManifest.currentSchemaVersion,
                sessionID: UUID,
                createdAt: Date,
                sessionStartHostTimeUs: Int64,
                sources: [CaptureSourceDescriptor],
                encoders: [UUID: CaptureEncoderConfig]) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.sessionStartHostTimeUs = sessionStartHostTimeUs
        self.sources = sources
        self.encoders = encoders
    }
}

public struct CaptureEpochRecord: Codable, Hashable, Sendable {
    public var atUs: Int64
    public var wallClock: Date

    public init(atUs: Int64, wallClock: Date) {
        self.atUs = atUs
        self.wallClock = wallClock
    }
}

public struct CaptureSourceEndedRecord: Codable, Hashable, Sendable {
    public var sourceID: UUID
    public var atUs: Int64
    public var durationUs: Int64
    public var timelineStartUs: Int64
    public var sampleCount: Int

    public init(sourceID: UUID,
                atUs: Int64,
                durationUs: Int64,
                timelineStartUs: Int64 = 0,
                sampleCount: Int) {
        self.sourceID = sourceID
        self.atUs = atUs
        self.durationUs = max(0, durationUs)
        self.timelineStartUs = max(0, timelineStartUs)
        self.sampleCount = max(0, sampleCount)
    }

    public var duration: CMTime {
        CMTime(value: durationUs, timescale: CaptureManifest.microsecondTimescale)
    }

    public var timelineStart: CMTime {
        CMTime(value: timelineStartUs, timescale: CaptureManifest.microsecondTimescale)
    }
}

public struct CaptureBackpressureRecord: Codable, Hashable, Sendable {
    public var sourceID: UUID
    public var atUs: Int64
    public var droppedSamples: Int
    public var reason: String

    public init(sourceID: UUID, atUs: Int64, droppedSamples: Int, reason: String) {
        self.sourceID = sourceID
        self.atUs = atUs
        self.droppedSamples = max(0, droppedSamples)
        self.reason = reason
    }
}

public struct CaptureFinalizeRecord: Codable, Hashable, Sendable {
    public var atUs: Int64
    public var durationUs: Int64

    public init(atUs: Int64, durationUs: Int64) {
        self.atUs = atUs
        self.durationUs = max(0, durationUs)
    }
}

public enum CaptureManifestRecord: Hashable, Sendable {
    case header(CaptureManifestHeader)
    case epoch(CaptureEpochRecord)
    case sourceEnded(CaptureSourceEndedRecord)
    case backpressure(CaptureBackpressureRecord)
    case finalize(CaptureFinalizeRecord)
    case unknown(kind: String)

    public var kind: String {
        switch self {
        case .header: "header"
        case .epoch: "epoch"
        case .sourceEnded: "source-ended"
        case .backpressure: "backpressure"
        case .finalize: "finalize"
        case .unknown(let kind): kind
        }
    }
}

extension CaptureManifestRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion
        case sessionID
        case createdAt
        case sessionStartHostTimeUs
        case sources
        case encoders
        case atUs
        case wallClock
        case sourceID
        case durationUs
        case sampleCount
        case timelineStartUs
        case droppedSamples
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "header":
            self = .header(try CaptureManifestHeader(from: decoder))
        case "epoch":
            self = .epoch(try CaptureEpochRecord(from: decoder))
        case "source-ended":
            self = .sourceEnded(try CaptureSourceEndedRecord(from: decoder))
        case "backpressure":
            self = .backpressure(try CaptureBackpressureRecord(from: decoder))
        case "finalize":
            self = .finalize(try CaptureFinalizeRecord(from: decoder))
        default:
            self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .header(let value):
            try container.encode(value.schemaVersion, forKey: .schemaVersion)
            try container.encode(value.sessionID, forKey: .sessionID)
            try container.encode(value.createdAt, forKey: .createdAt)
            try container.encode(value.sessionStartHostTimeUs, forKey: .sessionStartHostTimeUs)
            try container.encode(value.sources, forKey: .sources)
            try container.encode(value.encoders, forKey: .encoders)
        case .epoch(let value):
            try container.encode(value.atUs, forKey: .atUs)
            try container.encode(value.wallClock, forKey: .wallClock)
        case .sourceEnded(let value):
            try container.encode(value.sourceID, forKey: .sourceID)
            try container.encode(value.atUs, forKey: .atUs)
            try container.encode(value.durationUs, forKey: .durationUs)
            try container.encode(value.timelineStartUs, forKey: .timelineStartUs)
            try container.encode(value.sampleCount, forKey: .sampleCount)
        case .backpressure(let value):
            try container.encode(value.sourceID, forKey: .sourceID)
            try container.encode(value.atUs, forKey: .atUs)
            try container.encode(value.droppedSamples, forKey: .droppedSamples)
            try container.encode(value.reason, forKey: .reason)
        case .finalize(let value):
            try container.encode(value.atUs, forKey: .atUs)
            try container.encode(value.durationUs, forKey: .durationUs)
        case .unknown(let kind):
            try container.encode(kind, forKey: .kind)
        }
    }
}

public struct CaptureRecoveredSource: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var descriptor: CaptureSourceDescriptor
    public var duration: CMTime
    public var sampleCount: Int
    public var droppedSamples: Int

    public init(descriptor: CaptureSourceDescriptor,
                duration: CMTime,
                sampleCount: Int,
                droppedSamples: Int) {
        self.id = descriptor.id
        self.descriptor = descriptor
        self.duration = duration
        self.sampleCount = sampleCount
        self.droppedSamples = max(0, droppedSamples)
    }
}

public struct CaptureManifest: Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let microsecondTimescale: CMTimeScale = 1_000_000

    public var records: [CaptureManifestRecord]

    public init(records: [CaptureManifestRecord] = []) {
        self.records = records
    }

    public var header: CaptureManifestHeader? {
        records.compactMap {
            if case .header(let header) = $0 { header } else { nil }
        }.last
    }

    public var finalize: CaptureFinalizeRecord? {
        records.compactMap {
            if case .finalize(let finalize) = $0 { finalize } else { nil }
        }.last
    }

    public var isFinalized: Bool { finalize != nil }

    public var recoveredSources: [CaptureRecoveredSource] {
        guard let header else { return [] }
        let endedByID = Dictionary(
            records.compactMap {
                if case .sourceEnded(let ended) = $0 { (ended.sourceID, ended) } else { nil }
            },
            uniquingKeysWith: { _, latest in latest })
        let droppedByID = records.reduce(into: [UUID: Int]()) { result, record in
            guard case .backpressure(let backpressure) = record else { return }
            result[backpressure.sourceID, default: 0] += backpressure.droppedSamples
        }

        return header.sources.map { source in
            let ended = endedByID[source.id]
            var descriptor = source
            if let ended {
                descriptor.timelineStartUs = ended.timelineStartUs
            }
            return CaptureRecoveredSource(
                descriptor: descriptor,
                duration: ended?.duration ?? .zero,
                sampleCount: ended?.sampleCount ?? 0,
                droppedSamples: droppedByID[source.id, default: 0])
        }
    }

    public static func parseNDJSON(_ data: Data,
                                   decoder: JSONDecoder = CaptureManifestJSON.decoder) -> CaptureManifest {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // A crash can interrupt a write mid-record, leaving a final line without
        // its terminating newline. Such a record may be truncated (or, worse, a
        // syntactically valid but partial `finalize`), so only trust complete,
        // newline-terminated lines: drop the trailing segment when the data
        // doesn't end in "\n".
        if !text.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }
        var records: [CaptureManifestRecord] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(CaptureManifestRecord.self, from: lineData) else {
                continue
            }
            records.append(record)
        }
        return CaptureManifest(records: records)
    }

    public func encodeNDJSON(encoder: JSONEncoder = CaptureManifestJSON.encoder) throws -> Data {
        var data = Data()
        for record in records {
            data.append(try Self.lineData(for: record, encoder: encoder))
        }
        return data
    }

    public static func lineData(for record: CaptureManifestRecord,
                                encoder: JSONEncoder = CaptureManifestJSON.encoder) throws -> Data {
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    public static func microseconds(from time: CMTime) -> Int64 {
        guard time.isValid, !time.isIndefinite, time.timescale > 0 else { return 0 }
        let converted = time.convertScale(microsecondTimescale, method: .default)
        return max(0, converted.value)
    }

    public static func time(fromMicroseconds value: Int64) -> CMTime {
        CMTime(value: max(0, value), timescale: microsecondTimescale)
    }
}

public enum CaptureManifestJSON {
    // Configured once and shared: JSONEncoder/JSONDecoder hold no caller-visible
    // mutable state across encode/decode calls, so a single instance avoids
    // reallocating on every manifest line.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
