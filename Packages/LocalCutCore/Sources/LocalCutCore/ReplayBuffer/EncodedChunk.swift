import Foundation
import CoreMedia

// MARK: - Encoded chunk media type

public enum EncodedChunkMediaType: String, Hashable, Sendable, Codable {
    case video
    case audio
}

// MARK: - Encoded chunk

/// A reference to a segment of encoded video/audio in a capture writer's
/// output file, suitable for ring-buffer storage and eventual finalisation
/// into a playable `.mov`.
///
/// Each chunk records the source file URL and time range so the finalizer
/// can use `AVAssetReader` to extract the segment with proper movie headers.
/// Raw encoded bytes are NOT stored in memory — the source file is read
/// only during finalization.
public struct EncodedChunk: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Presentation timestamp of the first sample on the capture-session
    /// timeline. This is used for cross-source alignment and save-span
    /// selection.
    public let presentationTimeStamp: CMTime
    /// Decode timestamp on the capture-session timeline.
    public let decodeTimeStamp: CMTime
    /// Presentation timestamp of the first sample in the source file.
    public let sourceTimeStamp: CMTime
    /// Duration of this chunk, if known.
    public let duration: CMTime
    /// Byte size of the encoded data (for diagnostics/accounting).
    public let byteSize: Int
    /// Whether this chunk starts on a video keyframe / sync sample. Audio
    /// chunks are always sync chunks.
    public let isKeyframe: Bool
    /// The media type carried by the chunk.
    public let mediaType: EncodedChunkMediaType
    /// The track/source this chunk belongs to.
    public let sourceID: UUID
    /// The capture writer's output file containing this chunk's encoded data.
    public let sourceFileURL: URL

    public init(id: UUID = UUID(),
                presentationTimeStamp: CMTime,
                decodeTimeStamp: CMTime? = nil,
                sourceTimeStamp: CMTime? = nil,
                duration: CMTime,
                byteSize: Int,
                isKeyframe: Bool,
                mediaType: EncodedChunkMediaType = .video,
                sourceID: UUID,
                sourceFileURL: URL) {
        self.id = id
        self.presentationTimeStamp = presentationTimeStamp
        self.decodeTimeStamp = decodeTimeStamp ?? presentationTimeStamp
        self.sourceTimeStamp = sourceTimeStamp ?? presentationTimeStamp
        self.duration = duration
        self.byteSize = byteSize
        self.isKeyframe = isKeyframe
        self.mediaType = mediaType
        self.sourceID = sourceID
        self.sourceFileURL = sourceFileURL
    }

    /// End time of this chunk (PTS + duration).
    public var endTime: CMTime {
        presentationTimeStamp + duration
    }

    /// Time range for AVAssetReader extraction.
    public var timeRange: CMTimeRange {
        CMTimeRange(start: presentationTimeStamp, duration: duration)
    }

    /// Time range inside the source file for AVAssetReader extraction.
    public var sourceTimeRange: CMTimeRange {
        CMTimeRange(start: sourceTimeStamp, duration: duration)
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
        // `kCMSampleAttachmentKey_NotSync` is commonly present on compressed
        // inter frames read from AVAssetReader.
        if let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            return !notSync
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
