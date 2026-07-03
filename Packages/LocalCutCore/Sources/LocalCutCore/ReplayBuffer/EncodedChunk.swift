import Foundation
import CoreMedia

// MARK: - Encoded chunk

/// A single encoded video/audio fragment from a capture writer, suitable for
/// ring-buffer storage and eventual finalisation into a fragmented `.mov`.
///
/// Each chunk represents one self-contained, decodable fragment (typically a
/// GOP) produced by `AVAssetWriter`'s `movieFragmentInterval` mechanism. The
/// chunk stores the raw encoded bytes so they can be reassembled without
/// re-encoding.
public struct EncodedChunk: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Presentation timestamp of the first sample in this chunk.
    public let presentationTimeStamp: CMTime
    /// Decode timestamp (may equal PTS for simple streams).
    public let decodeTimeStamp: CMTime
    /// Duration of this chunk, if known.
    public let duration: CMTime
    /// Byte size of the encoded data.
    public let byteSize: Int
    /// Whether this chunk starts on a keyframe / sync sample. For
    /// `movieFragmentInterval`-produced fragments this is always `true`.
    public let isKeyframe: Bool
    /// The track/source this chunk belongs to.
    public let sourceID: UUID
    /// The encoded data. Nil when the chunk has been spilled to disk.
    public private(set) var data: Data?

    /// File URL where this chunk is spilled on disk. Nil when held in memory.
    public internal(set) var spillURL: URL?

    /// Whether this chunk's data is currently held in memory.
    public var isInMemory: Bool { data != nil }

    /// Whether this chunk has been spilled to disk.
    public var isSpilled: Bool { spillURL != nil }

    /// Effective byte size for memory accounting (only counts in-memory data).
    public var memoryBytes: Int { data?.count ?? 0 }

    public init(id: UUID = UUID(),
                presentationTimeStamp: CMTime,
                decodeTimeStamp: CMTime? = nil,
                duration: CMTime,
                byteSize: Int,
                isKeyframe: Bool,
                sourceID: UUID,
                data: Data?) {
        self.id = id
        self.presentationTimeStamp = presentationTimeStamp
        self.decodeTimeStamp = decodeTimeStamp ?? presentationTimeStamp
        self.duration = duration
        self.byteSize = byteSize
        self.isKeyframe = isKeyframe
        self.sourceID = sourceID
        self.data = data
    }

    /// End time of this chunk (PTS + duration).
    public var endTime: CMTime {
        presentationTimeStamp + duration
    }

    /// Clears the in-memory data after spilling to disk.
    public mutating func clearMemoryData() {
        data = nil
    }

    /// Loads data from the spill URL back into memory.
    public mutating func loadDataFromSpill() throws {
        guard let url = spillURL else { return }
        data = try Data(contentsOf: url)
    }
}

// MARK: - Keyframe detection

/// Utilities for detecting keyframes from `CMSampleBuffer` sample attachments.
public enum KeyframeDetector {

    /// Returns `true` if the given `CMSampleBuffer` is a keyframe / sync sample.
    ///
    /// Checks the sample attachment dictionary for the standard
    /// `kCMSampleAttachmentKey_DependsOnOthers` flag. When the flag is absent
    /// or `false`, the sample does not depend on others (i.e., it is a
    /// keyframe).
    public static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else {
            // No attachments — assume keyframe (e.g., first frame).
            return true
        }
        // `kCMSampleAttachmentKey_DependsOnOthers` is `true` for inter-frames.
        if let depends = first[kCMSampleAttachmentKey_DependsOnOthers as String] as? Bool {
            return !depends
        }
        // If the key is not present, assume keyframe.
        return true
    }

    /// Extracts the presentation timestamp from a `CMSampleBuffer`.
    public static func presentationTimeStamp(_ sampleBuffer: CMSampleBuffer) -> CMTime {
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    /// Extracts the decode timestamp from a `CMSampleBuffer`.
    public static func decodeTimeStamp(_ sampleBuffer: CMSampleBuffer) -> CMTime {
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        return dts.isValid ? dts : CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    /// Returns the data size in bytes of a `CMSampleBuffer` (total sample size).
    public static func byteSize(_ sampleBuffer: CMSampleBuffer) -> Int {
        Int(CMSampleBufferGetTotalSampleSize(sampleBuffer))
    }
}
