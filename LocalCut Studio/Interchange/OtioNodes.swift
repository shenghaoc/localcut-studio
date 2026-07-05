import Foundation

// MARK: - OTIO Schema Allowlist

/// The set of OTIO schema names this serializer may emit.
enum OtioSchema: String, Sendable {
    case timeline = "Timeline.1"
    case stack = "Stack.1"
    case track = "Track.1"
    case clip = "Clip.2"
    case gap = "Gap.1"
    case transition = "Transition.1"
    case marker = "Marker.2"
    case externalReference = "ExternalReference.1"
    case generatorReference = "GeneratorReference.1"
    case missingReference = "MissingReference.1"
    case rationalTime = "RationalTime.1"
    case timeRange = "TimeRange.1"

    static let allowlist: Set<String> = Set(OtioSchema.allCases.map(\.rawValue))
}

extension OtioSchema: CaseIterable {}

// MARK: - OTIO Node Protocol

/// A node that can be serialized to an OTIO-compatible dictionary.
protocol OtioNode: Sendable {
    var otioSchema: OtioSchema { get }
    func toDictionary() -> [String: Any]
}

// MARK: - RationalTime

struct OtioRationalTime: OtioNode {
    let value: Int
    let rate: Int

    var otioSchema: OtioSchema { .rationalTime }

    func toDictionary() -> [String: Any] {
        [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "value": value,
            "rate": rate,
        ]
    }
}

// MARK: - TimeRange

struct OtioTimeRange: OtioNode {
    let startTime: OtioRationalTime
    let duration: OtioRationalTime

    var otioSchema: OtioSchema { .timeRange }

    func toDictionary() -> [String: Any] {
        [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "start_time": startTime.toDictionary(),
            "duration": duration.toDictionary(),
        ]
    }
}

// MARK: - ExternalReference

struct OtioExternalReference: OtioNode {
    let targetURL: String
    let name: String?
    let fingerprint: String?
    let availableRange: OtioTimeRange?

    var otioSchema: OtioSchema { .externalReference }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "target_url": targetURL,
        ]
        if let name { dict["name"] = name }
        if let availableRange { dict["available_range"] = availableRange.toDictionary() }
        if let fingerprint {
            dict["metadata"] = [
                "localcut": ["fingerprint": fingerprint]
            ]
        }
        return dict
    }
}

// MARK: - GeneratorReference

struct OtioGeneratorReference: OtioNode {
    let generatorKind: String
    let name: String?
    let availableRange: OtioTimeRange?
    let parameters: [String: Any]?

    var otioSchema: OtioSchema { .generatorReference }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "generator_kind": generatorKind,
        ]
        if let name { dict["name"] = name }
        if let availableRange { dict["available_range"] = availableRange.toDictionary() }
        if let parameters { dict["parameters"] = parameters }
        return dict
    }
}

// MARK: - MissingReference

struct OtioMissingReference: OtioNode {
    let name: String?

    var otioSchema: OtioSchema { .missingReference }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "OTIO_SCHEMA": otioSchema.rawValue,
        ]
        if let name { dict["name"] = name }
        return dict
    }
}

// MARK: - Media Reference Union

enum OtioMediaReference: Sendable {
    case external(OtioExternalReference)
    case generator(OtioGeneratorReference)
    case missing(OtioMissingReference)

    func toDictionary() -> [String: Any] {
        switch self {
        case .external(let ref): return ref.toDictionary()
        case .generator(let ref): return ref.toDictionary()
        case .missing(let ref): return ref.toDictionary()
        }
    }
}

// MARK: - Gap

struct OtioGap: OtioNode {
    let sourceRange: OtioTimeRange?
    let name: String?

    var otioSchema: OtioSchema { .gap }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "OTIO_SCHEMA": otioSchema.rawValue,
        ]
        if let sourceRange { dict["source_range"] = sourceRange.toDictionary() }
        if let name { dict["name"] = name }
        return dict
    }
}

// MARK: - Marker

struct OtioMarker: OtioNode {
    let name: String
    let markedRange: OtioTimeRange
    let color: String

    var otioSchema: OtioSchema { .marker }

    func toDictionary() -> [String: Any] {
        [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "name": name,
            "marked_range": markedRange.toDictionary(),
            "color": color,
        ]
    }
}

// MARK: - Transition

struct OtioTransition: OtioNode {
    let name: String
    let transitionType: String
    let inOffset: OtioRationalTime
    let outOffset: OtioRationalTime

    var otioSchema: OtioSchema { .transition }

    func toDictionary() -> [String: Any] {
        [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "name": name,
            "transition_type": transitionType,
            "in_offset": inOffset.toDictionary(),
            "out_offset": outOffset.toDictionary(),
        ]
    }
}

// MARK: - Clip

struct OtioClip: OtioNode {
    let name: String
    let sourceRange: OtioTimeRange
    let mediaReferences: [String: OtioMediaReference]
    let activeKey: String
    let metadata: [String: Any]?

    var otioSchema: OtioSchema { .clip }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "name": name,
            "source_range": sourceRange.toDictionary(),
            "media_references": mediaReferences.mapValues { $0.toDictionary() },
            "active_media_reference_key": activeKey,
        ]
        if let metadata, !metadata.isEmpty {
            dict["metadata"] = metadata
        }
        return dict
    }
}

// MARK: - Track

enum OtioTrackKind: String, Sendable {
    case video = "Video"
    case audio = "Audio"
}

struct OtioTrack: OtioNode {
    let name: String
    let kind: OtioTrackKind
    let children: [OtioTrackChild]
    let metadata: [String: Any]?

    var otioSchema: OtioSchema { .track }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "name": name,
            "kind": kind.rawValue,
            "children": children.map { $0.toDictionary() },
        ]
        if let metadata, !metadata.isEmpty {
            dict["metadata"] = metadata
        }
        return dict
    }
}

enum OtioTrackChild: Sendable {
    case clip(OtioClip)
    case gap(OtioGap)
    case transition(OtioTransition)

    func toDictionary() -> [String: Any] {
        switch self {
        case .clip(let c): return c.toDictionary()
        case .gap(let g): return g.toDictionary()
        case .transition(let t): return t.toDictionary()
        }
    }
}

// MARK: - Stack

struct OtioStack: OtioNode {
    let name: String
    let children: [OtioStackChild]
    let markers: [OtioMarker]
    let metadata: [String: Any]?

    var otioSchema: OtioSchema { .stack }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "name": name,
            "children": children.map { $0.toDictionary() },
        ]
        if !markers.isEmpty {
            dict["markers"] = markers.map { $0.toDictionary() }
        }
        if let metadata, !metadata.isEmpty {
            dict["metadata"] = metadata
        }
        return dict
    }
}

enum OtioStackChild: Sendable {
    case track(OtioTrack)
    case gap(OtioGap)

    func toDictionary() -> [String: Any] {
        switch self {
        case .track(let t): return t.toDictionary()
        case .gap(let g): return g.toDictionary()
        }
    }
}

// MARK: - Timeline

struct OtioTimeline: OtioNode {
    let name: String
    let globalStartTime: OtioRationalTime
    let tracks: OtioStack
    let metadata: [String: Any]?

    var otioSchema: OtioSchema { .timeline }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "OTIO_SCHEMA": otioSchema.rawValue,
            "name": name,
            "global_start_time": globalStartTime.toDictionary(),
            "tracks": tracks.toDictionary(),
        ]
        if let metadata, !metadata.isEmpty {
            dict["metadata"] = metadata
        }
        return dict
    }
}
