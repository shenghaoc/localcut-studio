import Foundation

// MARK: - EDL Validation Error

enum EdlValidationError: Equatable, Sendable, CustomStringConvertible {
    case invalidEventNumber(String)
    case reelNameTooLong(String)
    case reelNameNotUppercaseAlphanumeric(String)
    case invalidTrackDesignator(String)
    case invalidTransitionField(String)
    case missingTimecode(String)
    case malformedLine(String)

    var description: String {
        switch self {
        case .invalidEventNumber(let line):
            return "Invalid event number: '\(line)'."
        case .reelNameTooLong(let name):
            return "Reel name too long (\(name.count) > 8): '\(name)'."
        case .reelNameNotUppercaseAlphanumeric(let name):
            return "Reel name not uppercase alphanumeric: '\(name)'."
        case .invalidTrackDesignator(let line):
            return "Invalid track designator: '\(line)'."
        case .invalidTransitionField(let line):
            return "Invalid transition/cut field: '\(line)'."
        case .missingTimecode(let line):
            return "Missing timecode: '\(line)'."
        case .malformedLine(let line):
            return "Malformed EDL line: '\(line)'."
        }
    }
}

// MARK: - EDL Validator

/// Validates a CMX3600 EDL string against the line grammar.
/// Used by tests and CI.
func validateEdl(_ edl: String) -> [EdlValidationError] {
    var errors: [EdlValidationError] = []
    let lines = edl.components(separatedBy: .newlines)

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }

        // Comment lines start with *
        if trimmed.hasPrefix("*") {
            // Check for LocalCut comment.
            if trimmed.hasPrefix("* LOCALCUT:") {
                // Valid LocalCut comment.
                continue
            }
            // Other comments are valid.
            continue
        }

        // TITLE line.
        if trimmed.hasPrefix("TITLE:") {
            continue
        }

        // Event line: "NNN  REEL     T     X     SSI SOO ROI ROO"
        errors.append(contentsOf: validateEventLine(trimmed))
    }

    return errors
}

/// Validates a single EDL event line.
private func validateEventLine(_ line: String) -> [EdlValidationError] {
    var errors: [EdlValidationError] = []

    // Split by whitespace, but timecodes have colons so they're fine.
    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 8 else {
        return [.malformedLine(line)]
    }

    // Event number: 3- or 4-digit integer (CMX3600 standard is 3 digits;
    // some tools accept 4 for timelines with > 999 cuts).
    let eventStr = String(parts[0])
    if let eventNum = Int(eventStr) {
        if eventNum < 1 || eventNum > 9999 || !(eventStr.count == 3 || eventStr.count == 4) {
            errors.append(.invalidEventNumber(eventStr))
        }
    } else {
        errors.append(.invalidEventNumber(eventStr))
    }

    // Reel name: max 8 chars, uppercase alphanumeric.
    let reel = String(parts[1])
    if reel.count > 8 {
        errors.append(.reelNameTooLong(reel))
    }
    let alphanumericSet = CharacterSet.uppercaseLetters.union(.decimalDigits)
    if reel.unicodeScalars.contains(where: { !alphanumericSet.contains($0) }) {
        errors.append(.reelNameNotUppercaseAlphanumeric(reel))
    }

    // Track designator: V or A followed by a digit.
    let track = String(parts[2])
    if !track.hasPrefix("V") && !track.hasPrefix("A") {
        errors.append(.invalidTrackDesignator(track))
    }

    // Transition/cut field: C, D, W, or similar.
    let transition = String(parts[3])
    let validTransitions: Set<String> = ["C", "D", "W001", "W002", "W003", "W004"]
    if !validTransitions.contains(transition) && !transition.hasPrefix("D") && !transition.hasPrefix("W") {
        errors.append(.invalidTransitionField(transition))
    }

    // Timecodes: 4 fields, each HH:MM:SS:FF format.
    let timecodeFields = [String(parts[4]), String(parts[5]), String(parts[6]), String(parts[7])]
    for tc in timecodeFields {
        if !isValidTimecode(tc) {
            errors.append(.missingTimecode(tc))
        }
    }

    return errors
}

/// Validates an SMPTE NDF timecode string: HH:MM:SS:FF.
private func isValidTimecode(_ tc: String) -> Bool {
    let components = tc.split(separator: ":")
    guard components.count == 4 else { return false }
    guard let h = Int(components[0]), h >= 0, h <= 99,
          let m = Int(components[1]), m >= 0, m <= 59,
          let s = Int(components[2]), s >= 0, s <= 59,
          let f = Int(components[3]), f >= 0, f <= 99 else { return false }
    // All components must be exactly 2 digits.
    return components.allSatisfy { $0.count == 2 }
}
