import Foundation

// MARK: - Cache

/// Binary, versioned, SHA-keyed cache for `BeatAnalysis` blobs. The header is a
/// 4-byte magic (`LCBT`) + little-endian `UInt32` version followed by the JSON
/// payload, so a format change can reject stale blobs by bumping `version`.
public enum BeatAnalysisCache: Sendable {
    private static let magic = Data([0x4C, 0x43, 0x42, 0x54]) // "LCBT"
    // v2: the tempo-octave correction changed estimator output, so v1 blobs
    // (which may hold the old half-tempo result) must be rejected and
    // re-analysed rather than served from the SHA-keyed cache.
    private static let version: UInt32 = 2
    public static let fileExtension = "beat"

    public static func fileName(for key: String) -> String {
        "\(key).\(fileExtension)"
    }

    public static func url(for key: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(for: key))
    }

    public static func read(key: String, in directory: URL) throws -> BeatAnalysis? {
        let fileURL = url(for: key, in: directory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        // A truncated or otherwise corrupt payload is treated as a cache miss
        // (returns nil) so the caller re-analyses and overwrites the bad blob,
        // rather than surfacing a hard failure for a perfectly readable source.
        return try? decode(data)
    }

    public static func write(_ analysis: BeatAnalysis, key: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encode(analysis)
        try data.write(to: url(for: key, in: directory), options: .atomic)
    }

    public static func encode(_ analysis: BeatAnalysis) throws -> Data {
        var data = Data()
        data.append(magic)
        appendUInt32(version, to: &data)
        let payload = try JSONEncoder().encode(analysis)
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> BeatAnalysis? {
        guard data.count >= magic.count + MemoryLayout<UInt32>.size,
              data.prefix(magic.count) == magic else { return nil }
        let encodedVersion = readUInt32(from: data, offset: magic.count)
        guard encodedVersion == version else { return nil }
        let payloadStart = magic.count + MemoryLayout<UInt32>.size
        let payload = data[payloadStart..<data.count]
        return try JSONDecoder().decode(BeatAnalysis.self, from: payload)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        // Copy the four bytes into an aligned local rather than `load(as:)`,
        // which requires the source offset to be 4-byte aligned — not guaranteed
        // for a sliced or arbitrarily backed `Data`, and an alignment fault on ARM.
        var value: UInt32 = 0
        let start = data.startIndex + offset
        withUnsafeMutableBytes(of: &value) { dest in
            _ = data.copyBytes(to: dest, from: start ..< start + 4)
        }
        return UInt32(littleEndian: value)
    }
}
