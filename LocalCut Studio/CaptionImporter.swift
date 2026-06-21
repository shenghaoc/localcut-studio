import Foundation
import AVFoundation
import os

/// Parses SRT and VTT sidecar files into `CaptionLine`s. Stateless; one call
/// per file. Word timings always come back `nil` here — Phase 29's ASR aligner
/// fills them later.
enum CaptionImporter {

    enum ImportError: Error, LocalizedError {
        case notUTF8
        case emptyDocument
        case malformedHeader

        var errorDescription: String? {
            switch self {
            case .notUTF8: "The file isn't valid UTF-8 text."
            case .emptyDocument: "The file contained no caption cues."
            case .malformedHeader: "The file is missing the required WEBVTT header."
            }
        }
    }

    /// Detects format from the URL extension; defaults to SRT.
    static func importTrack(from url: URL, name: String? = nil) throws -> CaptionTrack {
        let data = try Data(contentsOf: url)
        let isVTT = url.pathExtension.lowercased() == "vtt"
        return try importTrack(
            data: data,
            isVTT: isVTT,
            name: name ?? url.deletingPathExtension().lastPathComponent)
    }

    static func importTrack(data: Data, isVTT: Bool, name: String) throws -> CaptionTrack {
        guard let raw = String(data: data, encoding: .utf8) else { throw ImportError.notUTF8 }
        let lines = isVTT ? try parseVTT(raw) : parseSRT(raw)
        if lines.isEmpty { throw ImportError.emptyDocument }
        return CaptionTrack(name: name, lines: lines)
    }

    // MARK: - SRT

    /// SRT cue blocks separated by blank lines:
    ///   1
    ///   00:00:01,000 --> 00:00:04,000
    ///   Hello world
    static func parseSRT(_ raw: String) -> [CaptionLine] {
        let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalised.components(separatedBy: "\n\n")
        var out: [CaptionLine] = []

        for block in blocks {
            let stripped = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            var blockLines = stripped.components(separatedBy: "\n")

            // Optional cue numbering line — discard if it parses as Int.
            if let first = blockLines.first, Int(first.trimmingCharacters(in: .whitespaces)) != nil {
                blockLines.removeFirst()
            }
            guard !blockLines.isEmpty else { continue }

            let timingLine = blockLines.removeFirst()
            guard let range = parseTiming(timingLine, separator: ",") else {
                os_log(.debug, "SRT: skipping malformed cue at timing line: %{public}@", timingLine)
                continue
            }
            let text = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(CaptionLine(range: range, text: text))
        }
        return out
    }

    // MARK: - VTT

    /// VTT cue blocks under a mandatory `WEBVTT` header. `NOTE`, `STYLE`, and
    /// `REGION` blocks are skipped — Phase 30 keeps styling project-side.
    static func parseVTT(_ raw: String) throws -> [CaptionLine] {
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

            // Skip style / note / region blocks; they don't contain cue timings.
            let upper = stripped.uppercased()
            if upper.hasPrefix("NOTE") || upper.hasPrefix("STYLE") || upper.hasPrefix("REGION") {
                continue
            }

            var blockLines = stripped.components(separatedBy: "\n")
            // An optional cue identifier line precedes the timing; detected by
            // the absence of `-->`. Drop it.
            if let first = blockLines.first, !first.contains("-->") {
                blockLines.removeFirst()
            }
            guard !blockLines.isEmpty else { continue }

            let timingLine = blockLines.removeFirst()
            guard let range = parseTiming(timingLine, separator: ".") else {
                os_log(.debug, "VTT: skipping malformed cue at timing line: %{public}@", timingLine)
                continue
            }
            let text = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(CaptionLine(range: range, text: text))
        }
        return out
    }

    // MARK: - Timing

    /// Accepts `[hh:]mm:ss<separator>mmm --> [hh:]mm:ss<separator>mmm` (the
    /// separator distinguishes SRT `,` from VTT `.`). Trailing cue settings
    /// (`line:...`, `align:...`, etc.) after the second timestamp are ignored.
    static func parseTiming(_ line: String, separator: Character) -> CMTimeRange? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        guard let start = parseTimestamp(parts[0], separator: separator) else { return nil }

        let tail = parts[1].trimmingCharacters(in: .whitespaces)
        let endComponent = tail.split(separator: " ", maxSplits: 1).first.map(String.init) ?? tail
        guard let end = parseTimestamp(endComponent, separator: separator) else { return nil }
        guard end > start else { return nil }
        return CMTimeRange(start: start, duration: end - start)
    }

    /// Parses `hh:mm:ss<sep>mmm`. Hours are optional in VTT; falls back to `mm:ss`.
    static func parseTimestamp(_ raw: String, separator: Character) -> CMTime? {
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
        // SRT/VTT timestamps are unsigned by spec; treat a negative parse as
        // malformed rather than constructing a negative `CMTime` that would
        // shove a cue before the timeline origin.
        guard hours >= 0, minutes >= 0, seconds >= 0 else { return nil }

        let totalMs = Int64(hours) * 3_600_000 + Int64(minutes) * 60_000 + Int64(seconds) * 1_000 + Int64(ms)
        return CMTime(value: totalMs, timescale: 1_000)
    }
}
