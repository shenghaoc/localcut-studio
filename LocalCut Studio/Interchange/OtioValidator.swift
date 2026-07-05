import Foundation

// MARK: - OTIO Validation Error

enum OtioValidationError: Equatable, Sendable, CustomStringConvertible {
    case missingRequiredField(String, schema: String)
    case unsupportedSchema(String)
    case negativeDuration(String)
    case invalidClipMediaReference(String)
    case invalidStructure(String)

    var description: String {
        switch self {
        case .missingRequiredField(let field, let schema):
            return "Missing required field '\(field)' in \(schema)."
        case .unsupportedSchema(let schema):
            return "Unsupported OTIO schema: '\(schema)'."
        case .negativeDuration(let context):
            return "Negative duration in \(context)."
        case .invalidClipMediaReference(let detail):
            return "Invalid clip media reference: \(detail)."
        case .invalidStructure(let detail):
            return "Invalid OTIO structure: \(detail)."
        }
    }
}

// MARK: - OTIO Validator

/// Validates the structural correctness of a parsed OTIO JSON document.
/// Used by tests and CI; not shipped in the app.
func validateOtioDocument(_ data: Data) -> [OtioValidationError] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [.invalidStructure("Root is not a JSON object.")]
    }
    return validateOtioNode(root, path: "root")
}

func validateOtioDocument(_ jsonString: String) -> [OtioValidationError] {
    guard let data = jsonString.data(using: .utf8) else {
        return [.invalidStructure("String is not valid UTF-8.")]
    }
    return validateOtioDocument(data)
}

// MARK: - Node Validation

private func validateOtioNode(_ node: [String: Any], path: String) -> [OtioValidationError] {
    guard let schema = node["OTIO_SCHEMA"] as? String else {
        return [.missingRequiredField("OTIO_SCHEMA", schema: path)]
    }

    guard OtioSchema.allowlist.contains(schema) else {
        return [.unsupportedSchema(schema)]
    }

    var errors: [OtioValidationError] = []

    switch schema {
    case "Timeline.1":
        errors.append(contentsOf: validateTimeline(node, path: path))
    case "Stack.1":
        errors.append(contentsOf: validateStack(node, path: path))
    case "Track.1":
        errors.append(contentsOf: validateTrack(node, path: path))
    case "Clip.2":
        errors.append(contentsOf: validateClip(node, path: path))
    case "Gap.1":
        errors.append(contentsOf: validateGap(node, path: path))
    case "Transition.1":
        errors.append(contentsOf: validateTransition(node, path: path))
    case "Marker.2":
        errors.append(contentsOf: validateMarker(node, path: path))
    case "ExternalReference.1":
        errors.append(contentsOf: validateExternalReference(node, path: path))
    case "GeneratorReference.1":
        errors.append(contentsOf: validateGeneratorReference(node, path: path))
    case "MissingReference.1":
        // No required fields beyond OTIO_SCHEMA.
        break
    case "RationalTime.1":
        errors.append(contentsOf: validateRationalTime(node, path: path))
    case "TimeRange.1":
        errors.append(contentsOf: validateTimeRange(node, path: path))
    default:
        errors.append(.unsupportedSchema(schema))
    }

    return errors
}

// MARK: - Schema-Specific Validation

private func validateTimeline(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if node["name"] == nil {
        errors.append(.missingRequiredField("name", schema: "\(path)/Timeline.1"))
    }
    if node["global_start_time"] == nil {
        errors.append(.missingRequiredField("global_start_time", schema: "\(path)/Timeline.1"))
    } else if let gst = node["global_start_time"] as? [String: Any] {
        errors.append(contentsOf: validateRationalTime(gst, path: "\(path)/global_start_time"))
    }
    if let tracks = node["tracks"] as? [String: Any] {
        errors.append(contentsOf: validateStack(tracks, path: "\(path)/tracks"))
    } else {
        errors.append(.missingRequiredField("tracks", schema: "\(path)/Timeline.1"))
    }
    return errors
}

private func validateStack(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if node["name"] == nil {
        errors.append(.missingRequiredField("name", schema: "\(path)/Stack.1"))
    }
    if let children = node["children"] as? [[String: Any]] {
        for (index, child) in children.enumerated() {
            errors.append(contentsOf: validateOtioNode(child, path: "\(path)/children[\(index)]"))
        }
    }
    if let markers = node["markers"] as? [[String: Any]] {
        for (index, marker) in markers.enumerated() {
            errors.append(contentsOf: validateOtioNode(marker, path: "\(path)/markers[\(index)]"))
        }
    }
    return errors
}

private func validateTrack(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if node["name"] == nil {
        errors.append(.missingRequiredField("name", schema: "\(path)/Track.1"))
    }
    if node["kind"] == nil {
        errors.append(.missingRequiredField("kind", schema: "\(path)/Track.1"))
    }
    if let children = node["children"] as? [[String: Any]] {
        for (index, child) in children.enumerated() {
            errors.append(contentsOf: validateOtioNode(child, path: "\(path)/children[\(index)]"))
        }
    }
    return errors
}

private func validateClip(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if node["name"] == nil {
        errors.append(.missingRequiredField("name", schema: "\(path)/Clip.2"))
    }
    if let sr = node["source_range"] as? [String: Any] {
        errors.append(contentsOf: validateTimeRange(sr, path: "\(path)/source_range"))
        // Check non-negative duration.
        if let dur = sr["duration"] as? [String: Any],
           let value = dur["value"] as? Int, value < 0 {
            errors.append(.negativeDuration("\(path)/source_range/duration"))
        }
    } else {
        errors.append(.missingRequiredField("source_range", schema: "\(path)/Clip.2"))
    }
    // Clip.2 must have media_references map and active_media_reference_key.
    if node["media_references"] == nil {
        errors.append(.missingRequiredField("media_references", schema: "\(path)/Clip.2"))
    }
    if node["active_media_reference_key"] == nil {
        errors.append(.missingRequiredField("active_media_reference_key", schema: "\(path)/Clip.2"))
    } else if let activeKey = node["active_media_reference_key"] as? String,
              let refs = node["media_references"] as? [String: Any],
              refs[activeKey] == nil {
        errors.append(.invalidClipMediaReference("active_media_reference_key '\(activeKey)' not found in media_references."))
    }
    return errors
}

private func validateGap(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if let sr = node["source_range"] as? [String: Any] {
        errors.append(contentsOf: validateTimeRange(sr, path: "\(path)/source_range"))
    }
    return errors
}

private func validateTransition(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if node["name"] == nil {
        errors.append(.missingRequiredField("name", schema: "\(path)/Transition.1"))
    }
    if node["transition_type"] == nil {
        errors.append(.missingRequiredField("transition_type", schema: "\(path)/Transition.1"))
    }
    if let inOffset = node["in_offset"] as? [String: Any] {
        errors.append(contentsOf: validateRationalTime(inOffset, path: "\(path)/in_offset"))
    } else {
        errors.append(.missingRequiredField("in_offset", schema: "\(path)/Transition.1"))
    }
    if let outOffset = node["out_offset"] as? [String: Any] {
        errors.append(contentsOf: validateRationalTime(outOffset, path: "\(path)/out_offset"))
    } else {
        errors.append(.missingRequiredField("out_offset", schema: "\(path)/Transition.1"))
    }
    return errors
}

private func validateMarker(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if node["name"] == nil {
        errors.append(.missingRequiredField("name", schema: "\(path)/Marker.2"))
    }
    if let mr = node["marked_range"] as? [String: Any] {
        errors.append(contentsOf: validateTimeRange(mr, path: "\(path)/marked_range"))
    } else {
        errors.append(.missingRequiredField("marked_range", schema: "\(path)/Marker.2"))
    }
    if node["color"] == nil {
        errors.append(.missingRequiredField("color", schema: "\(path)/Marker.2"))
    }
    return errors
}

private func validateExternalReference(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if node["target_url"] == nil {
        errors.append(.missingRequiredField("target_url", schema: "\(path)/ExternalReference.1"))
    }
    if let ar = node["available_range"] as? [String: Any] {
        errors.append(contentsOf: validateTimeRange(ar, path: "\(path)/available_range"))
    }
    return errors
}

private func validateGeneratorReference(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if node["generator_kind"] == nil {
        errors.append(.missingRequiredField("generator_kind", schema: "\(path)/GeneratorReference.1"))
    }
    if let ar = node["available_range"] as? [String: Any] {
        errors.append(contentsOf: validateTimeRange(ar, path: "\(path)/available_range"))
    }
    return errors
}

private func validateRationalTime(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if node["value"] == nil {
        errors.append(.missingRequiredField("value", schema: "\(path)/RationalTime.1"))
    }
    if node["rate"] == nil {
        errors.append(.missingRequiredField("rate", schema: "\(path)/RationalTime.1"))
    }
    return errors
}

private func validateTimeRange(_ node: [String: Any], path: String) -> [OtioValidationError] {
    var errors: [OtioValidationError] = []
    if let start = node["start_time"] as? [String: Any] {
        errors.append(contentsOf: validateRationalTime(start, path: "\(path)/start_time"))
    } else {
        errors.append(.missingRequiredField("start_time", schema: "\(path)/TimeRange.1"))
    }
    if let dur = node["duration"] as? [String: Any] {
        errors.append(contentsOf: validateRationalTime(dur, path: "\(path)/duration"))
        if let value = dur["value"] as? Int, value < 0 {
            errors.append(.negativeDuration("\(path)/duration"))
        }
    } else {
        errors.append(.missingRequiredField("duration", schema: "\(path)/TimeRange.1"))
    }
    return errors
}
