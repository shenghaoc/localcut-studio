import Foundation
import CoreMedia

/// Parses SRT and VTT sidecar files into `CaptionLine`s.
public enum CaptionImporter: Sendable {

    public enum ImportError: Error, LocalizedError, Sendable {
        case notUTF8
        case emptyDocument
        case malformedHeader

        public var errorDescription: String? {
            switch self {
            case .notUTF8: "The file isn't valid UTF-8 text."
            case .emptyDocument: "The file contained no caption cues."
            case .malformedHeader: "The file is missing the required WEBVTT header."
            }
        }
    }

    /// Pure parse path: returns just the `[CaptionLine]` array.
    public static func parseLines(data: Data, isVTT: Bool) throws -> [CaptionLine] {
        guard let decoded = String(data: data, encoding: .utf8) else { throw ImportError.notUTF8 }
        let raw = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        let lines = isVTT ? try parseVTT(raw) : parseSRT(raw)
        if lines.isEmpty { throw ImportError.emptyDocument }
        return lines
    }

    // MARK: - SRT

    public static func parseSRT(_ raw: String) -> [CaptionLine] {
        let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalised.components(separatedBy: "\n\n")
        var out: [CaptionLine] = []

        for block in blocks {
            let stripped = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            var blockLines = stripped.components(separatedBy: "\n")

            if let first = blockLines.first, Int(first.trimmingCharacters(in: .whitespaces)) != nil {
                blockLines.removeFirst()
            }
            guard !blockLines.isEmpty else { continue }

            let timingLine = blockLines.removeFirst()
            guard let range = parseTiming(timingLine, separator: ",") else { continue }
            let text = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(CaptionLine(range: range, text: text))
        }
        return out
    }

    // MARK: - VTT

    public static func parseVTT(_ raw: String) throws -> [CaptionLine] {
        let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
        let firstLine = normalised.components(separatedBy: "\n").first ?? ""
        guard firstLine.hasPrefix("WEBVTT") else { throw ImportError.malformedHeader }

        let body = String(normalised.dropFirst(firstLine.count))
        let blocks = body.components(separatedBy: "\n\n")
        var out: [CaptionLine] = []

        for block in blocks {
            let stripped = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }

            let upper = stripped.uppercased()
            if upper.hasPrefix("NOTE") || upper.hasPrefix("STYLE") || upper.hasPrefix("REGION") {
                continue
            }

            var blockLines = stripped.components(separatedBy: "\n")
            if let first = blockLines.first, !first.contains("-->") {
                blockLines.removeFirst()
            }
            guard !blockLines.isEmpty else { continue }

            let timingLine = blockLines.removeFirst()
            guard let range = parseTiming(timingLine, separator: ".") else { continue }
            let text = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(CaptionLine(range: range, text: text))
        }
        return out
    }

    // MARK: - Timing

    public static func parseTiming(_ line: String, separator: Character) -> CMTimeRange? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        guard let start = parseTimestamp(parts[0], separator: separator) else { return nil }

        let tail = parts[1].trimmingCharacters(in: .whitespaces)
        let endComponent = tail.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            .first.map(String.init) ?? tail
        guard let end = parseTimestamp(endComponent, separator: separator) else { return nil }
        guard end > start else { return nil }
        return CMTimeRange(start: start, duration: end - start)
    }

    public static func parseTimestamp(_ raw: String, separator: Character) -> CMTime? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let mainAndMs = trimmed.split(separator: separator, maxSplits: 1)
        guard mainAndMs.count == 2 else { return nil }
        let timeParts = mainAndMs[0].split(separator: ":").map(String.init)
        guard let ms = Int(mainAndMs[1]), ms >= 0, ms <= 999 else { return nil }

        var hours = 0, minutes = 0, seconds = 0
        switch timeParts.count {
        case 3:
            guard let h = Int(timeParts[0]), let m = Int(timeParts[1]), let s = Int(timeParts[2]) else { return nil }
            hours = h; minutes = m; seconds = s
        case 2:
            guard let m = Int(timeParts[0]), let s = Int(timeParts[1]) else { return nil }
            minutes = m; seconds = s
        default:
            return nil
        }
        guard hours >= 0, minutes >= 0, seconds >= 0 else { return nil }

        let totalMs = Int64(hours) * 3_600_000 + Int64(minutes) * 60_000 + Int64(seconds) * 1_000 + Int64(ms)
        return CMTime(value: totalMs, timescale: 1_000)
    }
}
