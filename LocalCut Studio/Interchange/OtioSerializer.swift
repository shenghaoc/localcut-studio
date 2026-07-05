import Foundation
import CoreMedia
import CoreGraphics
import LocalCutCore

// MARK: - OTIO Serialization Options

struct OtioSerializationOptions: Sendable {
    /// When true, media references use bundle-relative `media/...` paths.
    /// When false, original file names or display names are used.
    var bundleMode: Bool
    /// Closure to resolve a media source ID to a target URL string.
    var resolveTargetUrl: @Sendable (UUID) -> String
    /// Closure to resolve a media source ID to a stable content fingerprint.
    var resolveFingerprint: @Sendable (UUID) -> String?
    /// True when the media ID is backed by a currently resolved source.
    var isMediaResolved: @Sendable (UUID) -> Bool
    /// Include LocalCut-specific metadata under `metadata.localcut`.
    var includeLocalCutMetadata: Bool

    init(bundleMode: Bool = false,
         resolveTargetUrl: @Sendable @escaping (UUID) -> String = { $0.uuidString },
         resolveFingerprint: @Sendable @escaping (UUID) -> String? = { _ in nil },
         isMediaResolved: @Sendable @escaping (UUID) -> Bool = { _ in true },
         includeLocalCutMetadata: Bool = true) {
        self.bundleMode = bundleMode
        self.resolveTargetUrl = resolveTargetUrl
        self.resolveFingerprint = resolveFingerprint
        self.isMediaResolved = isMediaResolved
        self.includeLocalCutMetadata = includeLocalCutMetadata
    }
}

// MARK: - OTIO Serializer

/// Pure function: `ProjectDoc` + options → deterministic OTIO JSON + warnings.
func serializeTimelineToOtio(_ doc: ProjectDocument,
                              options: OtioSerializationOptions = OtioSerializationOptions())
    -> (json: String, warnings: [InterchangeWarning]) {
    var warnings: [InterchangeWarning] = []
    let timebase = interchangeTimebase(for: doc)

    // Build media lookup for fingerprint and display name.
    let mediaLookup = Dictionary(doc.media.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
    let transitionCuts = TransitionLayout.cuts(videoTracks: doc.videoTracks.map { track in
        track.clips.map { $0.makeClip() }
    })

    // Serialize tracks.
    var stackChildren: [OtioStackChild] = []

    for track in doc.videoTracks {
        let (trackNode, trackWarnings) = serializeTrack(
            track, kind: .video, timebase: timebase, mediaLookup: mediaLookup,
            transitionCuts: transitionCuts, options: options)
        stackChildren.append(.track(trackNode))
        warnings.append(contentsOf: trackWarnings)
    }

    for track in doc.audioTracks {
        let (trackNode, trackWarnings) = serializeTrack(
            track, kind: .audio, timebase: timebase, mediaLookup: mediaLookup,
            transitionCuts: transitionCuts, options: options)
        stackChildren.append(.track(trackNode))
        warnings.append(contentsOf: trackWarnings)
    }

    // Serialize markers on the stack.
    let markers = doc.markers.map { marker in
        serializeMarker(marker, timebase: timebase, transitionCuts: transitionCuts)
    }

    // Build timeline metadata with caption tracks and layout tracks.
    var timelineMeta: [String: Any] = [:]
    if options.includeLocalCutMetadata {
        var localcut: [String: Any] = [:]
        if !doc.captionTracks.isEmpty {
            localcut["captionTracks"] = doc.captionTracks.map { serializeCaptionTrack($0) }
        }
        if !doc.layoutTracks.isEmpty {
            localcut["layoutTracks"] = doc.layoutTracks.map { serializeLayoutTrack($0) }
        }
        if !localcut.isEmpty {
            timelineMeta["localcut"] = localcut
        }
    }

    let stack = OtioStack(
        name: "tracks",
        children: stackChildren,
        markers: markers,
        metadata: nil)

    let timeline = OtioTimeline(
        name: doc.name,
        globalStartTime: OtioRationalTime(value: 0, rate: timebase.rate),
        tracks: stack,
        metadata: timelineMeta.isEmpty ? nil : timelineMeta)

    // Encode to deterministic JSON.
    let dict = timeline.toDictionary()
    guard JSONSerialization.isValidJSONObject(dict) else {
        warnings.append(serializationFailureWarning(
            detail: "OTIO document contains values JSONSerialization cannot encode."))
        return ("{}", warnings)
    }
    let jsonData: Data
    do {
        jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed])
    } catch {
        warnings.append(serializationFailureWarning(detail: error.localizedDescription))
        return ("{}", warnings)
    }

    return (String(data: jsonData, encoding: .utf8) ?? "{}", warnings)
}

// MARK: - Track Serialization

private func serializeTrack(_ track: TrackDoc, kind: OtioTrackKind,
                            timebase: InterchangeTimebase,
                            mediaLookup: [UUID: MediaRef],
                            transitionCuts: [TransitionLayout.Cut],
                            options: OtioSerializationOptions)
    -> (OtioTrack, [InterchangeWarning]) {
    var warnings: [InterchangeWarning] = []
    var children: [OtioTrackChild] = []

    let effectiveClips = track.clips.map { clip -> ClipDoc in
        var adjusted = clip
        let authoredStart = clip.timelineStart.cmTime
        let effectiveStart = authoredStart - TransitionLayout.shift(at: authoredStart, cuts: transitionCuts)
        adjusted.timelineStart = CMTimeCode(effectiveStart)
        return adjusted
    }
    let snappedClips = snapTrackClips(effectiveClips, timebase: timebase)
    let keptClipIndices = Set(snappedClips.map(\.sourceIndex))
    for index in track.clips.indices where !keptClipIndices.contains(index) {
        warnings.append(zeroFrameClipWarning(
            mediaID: track.clips[index].mediaID, trackName: track.name))
    }

    // Build children with gaps between clips.
    var cursor = CMTime.zero
    let microGap = timebase.microGapThreshold

    for (index, ic) in snappedClips.enumerated() {
        let gapDuration = ic.timelineStart - cursor

        // Insert gap if there's space before this clip.
        if gapDuration > microGap {
            let gap = OtioGap(
                sourceRange: OtioTimeRange(
                    startTime: OtioRationalTime(value: 0, rate: timebase.rate),
                    duration: OtioRationalTime(
                        value: timebase.rationalValue(frames: timebase.frames(time: gapDuration)),
                        rate: timebase.rate)),
                name: nil)
            children.append(.gap(gap))
        }

        // Handle transition: the transition lives on the *trailing* clip.
        // Use the clamped overlap from TransitionLayout.cuts so the emitted
        // in_offset/out_offset agree with preview/export timing.  A zero
        // overlap means the clips are no longer adjacent (gap inserted above)
        // and the transition should be dropped as an orphan.
        if let transitionDoc = ic.doc.transition, index > 0 {
            let authoredStart = ic.doc.timelineStart.cmTime
            let clampedOverlap = transitionCuts.first(where: {
                abs($0.time.seconds - authoredStart.seconds) < TransitionLayout.adjacencyTolerance
            })?.overlap ?? .zero
            if clampedOverlap > .zero {
                let (transitionNode, transWarnings) = serializeTransition(
                    transitionDoc, clampedOverlap: clampedOverlap,
                    timebase: timebase, trackName: track.name,
                    clipID: ic.doc.mediaID)
                if let transitionNode {
                    children.append(.transition(transitionNode))
                }
                warnings.append(contentsOf: transWarnings)
            } else {
                // Transition overlap was clamped to zero — clips are not
                // adjacent or handles are too short.
                warnings.append(orphanTransitionWarning(
                    clipID: ic.doc.mediaID, trackName: track.name))
            }
        } else if ic.doc.transition != nil, index == 0 {
            // Orphan transition on first clip.
            warnings.append(orphanTransitionWarning(
                clipID: ic.doc.mediaID, trackName: track.name))
        }

        // Build clip node.
        let (clipNode, clipWarnings) = serializeClip(
            ic, kind: kind, timebase: timebase, mediaLookup: mediaLookup,
            options: options, trackName: track.name)
        children.append(.clip(clipNode))
        warnings.append(contentsOf: clipWarnings)

        cursor = ic.timelineEnd
    }

    // Track metadata.
    var trackMeta: [String: Any] = [:]
    if options.includeLocalCutMetadata, track.isMuted {
        trackMeta["localcut"] = ["isMuted": true]
    }

    let trackNode = OtioTrack(
        name: track.name,
        kind: kind,
        children: children,
        metadata: trackMeta.isEmpty ? nil : trackMeta)

    return (trackNode, warnings)
}

// MARK: - Clip Serialization

private func serializeClip(_ ic: InterchangeClip, kind: OtioTrackKind,
                           timebase: InterchangeTimebase,
                           mediaLookup: [UUID: MediaRef],
                           options: OtioSerializationOptions,
                           trackName: String)
    -> (OtioClip, [InterchangeWarning]) {
    var warnings: [InterchangeWarning] = []
    let mediaRef = mediaLookup[ic.mediaID]

    // Determine media reference.
    let mediaReference: OtioMediaReference
    if let ref = mediaRef, options.isMediaResolved(ic.mediaID) {
        let targetUrl = options.resolveTargetUrl(ic.mediaID)
        let availableRange: OtioTimeRange?
        if ref.duration.cmTime > .zero {
            availableRange = OtioTimeRange(
                startTime: OtioRationalTime(value: 0, rate: timebase.rate),
                duration: OtioRationalTime(
                    value: timebase.rationalValue(frames: timebase.frames(time: ref.duration.cmTime)),
                    rate: timebase.rate))
        } else {
            availableRange = nil
        }

        let extRef = OtioExternalReference(
            targetURL: targetUrl,
            name: ref.displayName,
            fingerprint: options.includeLocalCutMetadata ? options.resolveFingerprint(ic.mediaID) : nil,
            availableRange: availableRange)
        mediaReference = .external(extRef)
        warnings.append(contentsOf: checkMissingMedia(ref, trackName: trackName, clipName: ref.displayName))
    } else {
        // Missing source.
        let missingName = mediaRef?.displayName ?? "Missing-\(ic.mediaID.uuidString.prefix(8))"
        mediaReference = .missing(OtioMissingReference(name: missingName))
        warnings.append(missingSourceWarning(
            mediaID: ic.mediaID, trackName: trackName, clipName: mediaRef?.displayName))
    }

    // Active key for Clip.2.
    let activeKey = "DEFAULT_MEDIA"

    // Source range adjustment for speed curves.
    var adjustedSourceDuration = ic.sourceDuration
    var speedCurveMeta: [String: Any]? = nil

    if let speedCurve = ic.doc.speedCurve,
       TimeRemapping.hasNonIdentitySpeed(speedCurve) {
        // A foreign tool that ignores metadata.localcut plays source_range at
        // normal speed, so use the retimed timeline duration as the portable
        // approximation of this clip's output length.
        adjustedSourceDuration = ic.timelineDuration

        // Check if non-uniform.
        let isUniform = isSpeedCurveUniform(speedCurve)
        if !isUniform {
            warnings.append(nonUniformSpeedWarning(
                clipID: ic.doc.mediaID, trackName: trackName))
        }

        if options.includeLocalCutMetadata {
            speedCurveMeta = serializeSpeedCurve(speedCurve)
        }
    }

    // Build source range with adjusted duration.
    let sourceRange = OtioTimeRange(
        startTime: OtioRationalTime(
            value: timebase.rationalValue(frames: timebase.frames(time: ic.sourceStart)),
            rate: timebase.rate),
        duration: OtioRationalTime(
            value: timebase.rationalValue(frames: timebase.frames(time: adjustedSourceDuration)),
            rate: timebase.rate))

    // Build clip metadata.
    var clipMeta: [String: Any] = [:]
    if options.includeLocalCutMetadata {
        var localcut: [String: Any] = [:]

        // Effects.
        if !ic.doc.effects.isEmpty {
            localcut["effects"] = serializeEffects(ic.doc.effects)
        }

        // Transform keyframes.
        if let tk = ic.doc.transformKeyframes, !tk.keyframes.isEmpty {
            localcut["transformKeyframes"] = serializeKeyframedTransform(tk)
        }

        // Volume envelope.
        let ve = ic.doc.volumeEnvelope
        if !ve.isEmpty {
            var veDict: [String: Any] = [:]
            if ve.fadeIn > .zero {
                veDict["fadeIn"] = timebase.frames(time: ve.fadeIn)
            }
            if ve.fadeOut > .zero {
                veDict["fadeOut"] = timebase.frames(time: ve.fadeOut)
            }
            if !ve.ramps.isEmpty {
                veDict["ramps"] = ve.ramps.map { ramp in
                    [
                        "startFrame": timebase.frames(time: ramp.range.start),
                        "durationFrames": timebase.frames(time: ramp.range.duration),
                        "fromVolume": ramp.fromVolume,
                        "toVolume": ramp.toVolume,
                    ] as [String: Any]
                }
            }
            localcut["volumeEnvelope"] = veDict
        }

        // Speed curve.
        if let sc = speedCurveMeta {
            localcut["speedCurve"] = sc
        }

        // Preserve pitch.
        if let pp = ic.doc.preservePitch {
            localcut["preservePitch"] = pp
        }

        // Geometry.
        let geo = ic.doc.geometry
        if !geo.isIdentity {
            var geoDict: [String: Any] = [:]
            if geo.positionOffset != .zero {
                geoDict["positionOffsetX"] = geo.positionOffset.width
                geoDict["positionOffsetY"] = geo.positionOffset.height
            }
            if geo.scale != 1 { geoDict["scale"] = geo.scale }
            if geo.mask != .none { geoDict["mask"] = geo.mask.rawValue }
            localcut["geometry"] = geoDict
        }

        // Opacity.
        if ic.doc.opacity != 1 {
            localcut["opacity"] = ic.doc.opacity
        }

        if !localcut.isEmpty {
            clipMeta["localcut"] = localcut
        }
    }

    let clipName = mediaRef?.displayName ?? "Clip-\(ic.mediaID.uuidString.prefix(8))"
    let clipNode = OtioClip(
        name: clipName,
        sourceRange: sourceRange,
        mediaReferences: [activeKey: mediaReference],
        activeKey: activeKey,
        metadata: clipMeta.isEmpty ? nil : clipMeta)

    return (clipNode, warnings)
}

// MARK: - Transition Serialization

private func serializeTransition(_ doc: TransitionDoc, clampedOverlap: CMTime,
                                 timebase: InterchangeTimebase,
                                 trackName: String, clipID: UUID)
    -> (OtioTransition?, [InterchangeWarning]) {
    var warnings: [InterchangeWarning] = []
    let snappedDuration = timebase.snapToFrames(clampedOverlap)

    guard snappedDuration > .zero else {
        warnings.append(orphanTransitionWarning(clipID: clipID, trackName: trackName))
        return (nil, warnings)
    }

    let transitionType: String
    switch TransitionType(rawValue: doc.type) {
    case .crossDissolve:
        transitionType = "SMPTE_Dissolve"
    case .wipe:
        transitionType = "Custom_Transition"
    case .none:
        transitionType = "Custom_Transition"
    }

    // Split duration into in/out offsets.
    let halfFrames = timebase.frames(time: snappedDuration) / 2
    let inOffsetFrames = halfFrames
    let outOffsetFrames = timebase.frames(time: snappedDuration) - inOffsetFrames

    let transition = OtioTransition(
        name: doc.type,
        transitionType: transitionType,
        inOffset: OtioRationalTime(
            value: timebase.rationalValue(frames: inOffsetFrames),
            rate: timebase.rate),
        outOffset: OtioRationalTime(
            value: timebase.rationalValue(frames: outOffsetFrames),
            rate: timebase.rate))

    return (transition, warnings)
}

// MARK: - Marker Serialization

private func serializeMarker(_ marker: TimelineMarker,
                             timebase: InterchangeTimebase,
                             transitionCuts: [TransitionLayout.Cut]) -> OtioMarker {
    let effectiveTime = marker.time - TransitionLayout.shift(at: marker.time, cuts: transitionCuts)
    let snappedTime = timebase.snapToFrames(effectiveTime)
    let markedRange = OtioTimeRange(
        startTime: OtioRationalTime(
            value: timebase.rationalValue(frames: timebase.frames(time: snappedTime)),
            rate: timebase.rate),
        duration: OtioRationalTime(value: 0, rate: timebase.rate))

    let color: String
    if let c = marker.colour {
        // Map to nearest OTIO color.
        color = mapToOtioColor(c)
    } else {
        color = "PURPLE"
    }

    return OtioMarker(
        name: marker.name,
        markedRange: markedRange,
        color: color)
}

// MARK: - Caption Track Serialization

private func serializeCaptionTrack(_ track: CaptionTrackDoc) -> [String: Any] {
    var dict: [String: Any] = [
        "id": track.id.uuidString,
        "name": track.name,
        "isMuted": track.isMuted,
    ]
    if let defaultStyle = encodedJSONObject(track.defaultStyle) {
        dict["defaultStyle"] = defaultStyle
    }
    // Serialize lines.
    dict["lines"] = track.lines.map { line -> [String: Any] in
        var lineDict: [String: Any] = [
            "id": line.id.uuidString,
            "text": line.text,
            "startValue": line.range.start.value,
            "startScale": line.range.start.timescale,
            "durationValue": line.range.duration.value,
            "durationScale": line.range.duration.timescale,
        ]
        if let words = line.words, !words.isEmpty {
            lineDict["words"] = words.map { w in
                [
                    "word": w.word,
                    "startValue": w.range.start.value,
                    "startScale": w.range.start.timescale,
                    "durationValue": w.range.duration.value,
                    "durationScale": w.range.duration.timescale,
                ] as [String: Any]
            }
        }
        if let style = line.style,
           let styleObject = encodedJSONObject(style) {
            lineDict["style"] = styleObject
        }
        if let styleKeyframes = line.styleKeyframes,
           let keyframesObject = encodedJSONObject(styleKeyframes) {
            lineDict["styleKeyframes"] = keyframesObject
        }
        return lineDict
    }
    return dict
}

// MARK: - Layout Track Serialization

private func serializeLayoutTrack(_ track: LayoutTrackDoc) -> [String: Any] {
    var dict: [String: Any] = [
        "id": track.id.uuidString,
        "name": track.name,
        "isMuted": track.isMuted,
    ]
    dict["clips"] = track.clips.map { clip -> [String: Any] in
        var clipDict: [String: Any] = [
            "id": clip.id.uuidString,
            "startValue": clip.timelineStart.value,
            "startScale": clip.timelineStart.timescale,
            "durationValue": clip.duration.value,
            "durationScale": clip.duration.timescale,
            "sceneName": clip.sceneSnapshot.name,
            "layers": clip.sceneSnapshot.layers.map { layer -> [String: Any] in
                var layerDict: [String: Any] = [
                    "visible": layer.visible,
                    "zIndex": layer.zIndex,
                    "opacity": layer.opacity,
                    "transform": [
                        "a": layer.transform.a, "b": layer.transform.b,
                        "c": layer.transform.c, "d": layer.transform.d,
                        "tx": layer.transform.tx, "ty": layer.transform.ty,
                    ] as [String: Any],
                ]
                switch layer.sourceRef {
                case .captureSource(let id):
                    layerDict["sourceRef"] = ["captureSource": id.uuidString]
                case .still(let id):
                    layerDict["sourceRef"] = ["still": id.uuidString]
                case .colour(let hex):
                    layerDict["sourceRef"] = ["colour": hex]
                }
                return layerDict
            },
        ]
        return clipDict
    }
    return dict
}

// MARK: - Effect Serialization

private func serializeEffects(_ effects: [Effect]) -> [[String: Any]] {
    effects.map { effect in
        switch effect {
        case .colourGrade(let grade):
            return [
                "type": "colourGrade",
                "exposure": grade.exposure,
                "contrast": grade.contrast,
                "saturation": grade.saturation,
                "temperatureOffset": grade.temperatureOffset,
                "tintOffset": grade.tintOffset,
            ] as [String: Any]
        case .lut:
            // The persisted clip model only carries the security-scoped
            // bookmark. Do not serialize bookmark bytes or Swift hash values;
            // both are unstable/private. A future LUT sidecar model can add a
            // durable key + file name here.
            return [
                "type": "lut",
            ] as [String: Any]
        case .skinSmooth(let ss):
            var dict: [String: Any] = [
                "type": "skinSmooth",
                "strength": serializeKeyframedFloat(ss.strength),
                "maskWarmthBias": ss.maskWarmthBias,
                "maskLuminanceGate": ss.maskLuminanceGate,
            ]
            return dict
        case .grain(let g):
            return [
                "type": "grain",
                "amount": serializeKeyframedFloat(g.amount),
                "size": g.size,
                "monochrome": g.monochrome,
            ] as [String: Any]
        case .halation(let h):
            return [
                "type": "halation",
                "strength": serializeKeyframedFloat(h.strength),
                "threshold": h.threshold,
                "radius": h.radius,
                "redBoost": h.redBoost,
            ] as [String: Any]
        case .vignette(let v):
            return [
                "type": "vignette",
                "amount": serializeKeyframedFloat(v.amount),
                "radius": v.radius,
                "softness": v.softness,
            ] as [String: Any]
        }
    }
}

// MARK: - Transform Keyframe Serialization

private func serializeKeyframedTransform(_ keyframed: Keyframed<Transform2D>) -> [String: Any] {
    // Keyframed<Transform2D> — store the affine components as opaque metadata.
    let t = keyframed.defaultValue
    var dict: [String: Any] = [
        "defaultValue": serializeTransform(t),
    ]
    if !keyframed.keyframes.isEmpty {
        dict["keyframes"] = keyframed.keyframes.map { keyframe in
            var keyframeDict: [String: Any] = [
                "id": keyframe.id.uuidString,
                "timeValue": keyframe.time.value,
                "timeScale": keyframe.time.timescale,
                "value": serializeTransform(keyframe.value),
            ]
            if let incomingHandle = serializeKeyframeHandle(keyframe.incomingHandle) {
                keyframeDict["incomingHandle"] = incomingHandle
            }
            if let outgoingHandle = serializeKeyframeHandle(keyframe.outgoingHandle) {
                keyframeDict["outgoingHandle"] = outgoingHandle
            }
            return keyframeDict
        }
    }
    return dict
}

// MARK: - Speed Curve Serialization

private func serializeKeyframedFloat(_ curve: Keyframed<Float>) -> [String: Any] {
    var dict: [String: Any] = [
        "defaultValue": curve.defaultValue,
    ]
    if !curve.keyframes.isEmpty {
        dict["keyframes"] = curve.keyframes.map { kf in
            var keyframeDict: [String: Any] = [
                "id": kf.id.uuidString,
                "timeValue": kf.time.value,
                "timeScale": kf.time.timescale,
                "value": kf.value,
            ]
            if let incomingHandle = serializeKeyframeHandle(kf.incomingHandle) {
                keyframeDict["incomingHandle"] = incomingHandle
            }
            if let outgoingHandle = serializeKeyframeHandle(kf.outgoingHandle) {
                keyframeDict["outgoingHandle"] = outgoingHandle
            }
            return keyframeDict
        }
    }
    return dict
}

private func serializeSpeedCurve(_ curve: Keyframed<Float>) -> [String: Any] {
    serializeKeyframedFloat(curve)
}

// MARK: - Helpers

private func serializeTransform(_ transform: Transform2D) -> [String: Any] {
    [
        "a": transform.a,
        "b": transform.b,
        "c": transform.c,
        "d": transform.d,
        "tx": transform.tx,
        "ty": transform.ty,
    ] as [String: Any]
}

private func serializeKeyframeHandle(_ handle: KeyframeHandle?) -> [String: Any]? {
    guard let handle else { return nil }
    return [
        "x": handle.x,
        "y": handle.y,
    ]
}

private func encodedJSONObject<T: Encodable>(_ value: T) -> Any? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

private func checkMissingMedia(_ ref: MediaRef, trackName: String,
                                clipName: String?) -> [InterchangeWarning] {
    // If bookmark is empty and no bundle path, the media is unresolvable.
    if ref.bookmark.isEmpty, ref.bundleRelativePath == nil {
        return [missingSourceWarning(mediaID: ref.id, trackName: trackName, clipName: clipName)]
    }
    return []
}

private func mapToOtioColor(_ colour: RGBAColour) -> String {
    // Map to nearest OTIO marker color.
    let r = colour.red, g = colour.green, b = colour.blue
    if r > 0.8, g < 0.3, b < 0.3 { return "RED" }
    if r > 0.8, g > 0.8, b < 0.3 { return "YELLOW" }
    if r < 0.3, g > 0.8, b < 0.3 { return "GREEN" }
    if r < 0.3, g < 0.3, b > 0.8 { return "BLUE" }
    if r > 0.8, g > 0.5, b < 0.3 { return "ORANGE" }
    if r > 0.5, g < 0.3, b > 0.5 { return "PURPLE" }
    if r < 0.3, g > 0.5, b > 0.5 { return "CYAN" }
    if r > 0.8, g > 0.8, b > 0.8 { return "WHITE" }
    return "PURPLE" // Default.
}
