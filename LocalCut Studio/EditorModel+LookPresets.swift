import Foundation
import AppKit
import CoreMedia
import UniformTypeIdentifiers
import LocalCutCore

extension UTType {
    static let localCutLookPreset = UTType(filenameExtension: LookPresetV1.fileExtension,
                                          conformingTo: .json) ?? .json
}

extension EditorModel {
    // MARK: - Look effects

    var selectedClipHasLookEffects: Bool {
        guard let clip = selectedClip else { return false }
        return clip.effects.hasLookEffects || selectedClipLUT(clip) != nil
    }

    var selectedClipGrain: GrainEffect {
        get {
            guard let clip = selectedClip else { return .neutral }
            for effect in clip.effects {
                if case .grain(let grain) = effect { return grain }
            }
            return .neutral
        }
        set {
            updateSelectedClipLookEffect(.grain(newValue), actionName: "Adjust Grain")
        }
    }

    var selectedClipHalation: HalationEffect {
        get {
            guard let clip = selectedClip else { return .neutral }
            for effect in clip.effects {
                if case .halation(let halation) = effect { return halation }
            }
            return .neutral
        }
        set {
            updateSelectedClipLookEffect(.halation(newValue), actionName: "Adjust Halation")
        }
    }

    var selectedClipVignette: VignetteEffect {
        get {
            guard let clip = selectedClip else { return .neutral }
            for effect in clip.effects {
                if case .vignette(let vignette) = effect { return vignette }
            }
            return .neutral
        }
        set {
            updateSelectedClipLookEffect(.vignette(newValue), actionName: "Adjust Vignette")
        }
    }

    func updateSelectedClipGrain(_ transform: @escaping (inout GrainEffect) -> Void) {
        var grain = selectedClipGrain
        transform(&grain)
        grain.clamp()
        selectedClipGrain = grain
    }

    func updateSelectedClipHalation(_ transform: @escaping (inout HalationEffect) -> Void) {
        var halation = selectedClipHalation
        transform(&halation)
        halation.clamp()
        selectedClipHalation = halation
    }

    func updateSelectedClipVignette(_ transform: @escaping (inout VignetteEffect) -> Void) {
        var vignette = selectedClipVignette
        transform(&vignette)
        vignette.clamp()
        selectedClipVignette = vignette
    }

    func resetClipLooks() {
        guard let id = selectedVideoClipID else { return }
        performUndoable("Reset Looks") {
            for track in project.videoTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                track.clips[index].effects = track.clips[index].effects.removingLookEffects()
                RenderCache.shared.invalidate(clipID: id)
                statusMessage = "Reset look effects."
                scheduleRebuild()
                return
            }
        }
    }

    private func updateSelectedClipLookEffect(_ effect: Effect, actionName: String) {
        guard let id = selectedVideoClipID,
              effect.isLookEffect else { return }
        performCoalescedUndoable(actionName, target: id, rebuild: .debounced) {
            for track in project.videoTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                track.clips[index].effects = track.clips[index].effects.replacingLookEffect(effect)
                RenderCache.shared.invalidate(clipID: id)
                return
            }
        }
    }

    // MARK: - Look presets

    func applyBuiltInLookPreset(_ preset: LookPresetV1) {
        applyLookPreset(preset, lutBookmark: nil)
    }

    func importLookPreset(url: URL) async {
        // Capture the target clip now: the detached read below can take a while on
        // a slow location, and the user may select a different clip meanwhile. We
        // apply to the clip that was selected when the import started.
        guard let targetID = selectedVideoClipID else {
            statusMessage = "Select a video clip before importing a look preset."
            return
        }

        do {
            // Read, decode, and resolve the sidecar LUT bookmark off the main
            // actor: a preset on a slow network share or iCloud Drive would
            // otherwise block the UI, and the bookmark resolution does its own
            // disk I/O. Security-scoped access is thread-bound, so start/stop
            // must bracket the work in the same background context.
            let (preset, lutBookmark) = try await Task.detached {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                let data = try Data(contentsOf: url)
                let preset = try LookPresetV1(data: data)
                let bookmark = EditorModel.resolvePresetLUT(preset.lut, sourceURL: url)
                return (preset, bookmark)
            }.value

            applyLookPreset(preset, lutBookmark: lutBookmark, clipID: targetID)
        } catch {
            statusMessage = "Could not import \(url.lastPathComponent)."
        }
    }

    func requestExportLookPreset() {
        guard let clip = selectedClip,
              selectedVideoClipID != nil else {
            statusMessage = "Select a video clip before exporting a look preset."
            return
        }
        guard selectedClipHasLookEffects else {
            statusMessage = "The selected clip has no look effects to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.localCutLookPreset]
        panel.nameFieldStringValue = "\(defaultLookPresetName(for: clip)).\(LookPresetV1.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let export = lookExportPreset(for: clip, to: url)
        exportLookPreset(export.preset, to: url, lutBookmark: export.lutBookmark)
    }

    func exportLookPreset(to url: URL) {
        guard let clip = selectedClip,
              selectedVideoClipID != nil else {
            statusMessage = "Select a video clip before exporting a look preset."
            return
        }
        let export = lookExportPreset(for: clip, to: url)
        exportLookPreset(export.preset, to: url, lutBookmark: export.lutBookmark)
    }

    /// Builds the preset for `clip`, folding in the clip's LUT as a sidecar
    /// reference (named after the chosen preset file) when one is attached, so a
    /// re-imported `.lclook` can relink the LUT. Returns the LUT bookmark to copy
    /// alongside the preset — resolved off the main actor at write time.
    private func lookExportPreset(for clip: Clip, to url: URL) -> (preset: LookPresetV1, lutBookmark: Data?) {
        var preset = LookPresetV1(name: defaultLookPresetName(for: clip), effects: clip.effects)
        guard let lut = selectedClipLUT(clip) else { return (preset, nil) }
        let presetBase = url.deletingPathExtension().lastPathComponent
        let ext = (lut.displayName as NSString).pathExtension
        let lutFileName = "\(presetBase).\(ext.isEmpty ? "cube" : ext)"
        preset.lut = LookPresetLUTReference(relativePath: "assets/luts/\(lutFileName)",
                                            displayName: lut.displayName)
        return (preset, lut.bookmark)
    }

    /// The selected clip's LUT bookmark plus a display name. Reads only the cached
    /// name, so it never resolves the bookmark on the main actor.
    private func selectedClipLUT(_ clip: Clip) -> (bookmark: Data, displayName: String)? {
        for effect in clip.effects {
            guard case .lut(let bookmark) = effect else { continue }
            return (bookmark, lutDisplayNames[bookmark] ?? "LUT.cube")
        }
        return nil
    }

    private func exportLookPreset(_ preset: LookPresetV1, to url: URL, lutBookmark: Data?) {
        guard !preset.nodes.isEmpty || preset.lut != nil else {
            statusMessage = "The selected clip has no look effects to export."
            return
        }
        let withLUT = lutBookmark != nil && preset.lut != nil
        Task {
            do {
                // Encode is cheap, but the disk writes can stall on a slow network
                // share or iCloud Drive, so push them off the main actor. The .lclook
                // write is required; the sidecar LUT copy is best-effort so a sandbox
                // or copy failure still exports the preset (the reference then prompts
                // a relink on import) rather than failing the whole export.
                let data = try preset.encoded()
                let copiedLUT = try await Task.detached { () -> Bool in
                    let didAccessDestination = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccessDestination { url.stopAccessingSecurityScopedResource() }
                    }
                    try data.write(to: url, options: [.atomic])
                    guard let lutBookmark, let reference = preset.lut else { return false }
                    var isStale = false
                    guard let source = try? URL(resolvingBookmarkData: lutBookmark,
                                                options: .withSecurityScope,
                                                relativeTo: nil,
                                                bookmarkDataIsStale: &isStale) else { return false }
                    let didAccess = source.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { source.stopAccessingSecurityScopedResource() }
                    }
                    let destination = url.deletingLastPathComponent()
                        .appendingPathComponent(reference.relativePath)
                    if destination.standardizedFileURL == source.standardizedFileURL { return true }
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: destination)
                    do {
                        try FileManager.default.copyItem(at: source, to: destination)
                        return true
                    } catch {
                        return false
                    }
                }.value
                statusMessage = !withLUT
                    ? "Exported look preset \(url.lastPathComponent)."
                    : (copiedLUT
                        ? "Exported look preset \(url.lastPathComponent) with LUT."
                        : "Exported look preset \(url.lastPathComponent); LUT not copied.")
            } catch {
                statusMessage = "Could not export \(url.lastPathComponent)."
            }
        }
    }

    private func applyLookPreset(_ preset: LookPresetV1, lutBookmark: Data?, clipID: Clip.ID? = nil) {
        guard let id = clipID ?? selectedVideoClipID else {
            statusMessage = "Select a video clip before applying a look preset."
            return
        }
        // The target may have been deleted while an import read off the main actor.
        guard track(for: id)?.kind == .video else {
            statusMessage = "The clip is no longer available."
            return
        }

        performUndoable("Apply Look Preset") {
            for track in project.videoTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                var effects = preset.applying(to: track.clips[index].effects)
                if let lutBookmark {
                    effects = effects.replacingLUT(bookmark: lutBookmark)
                } else if preset.lut != nil {
                    // The preset declares a LUT we could not resolve. Drop any LUT
                    // already on the clip so we render a neutral/relink state rather
                    // than a stale LUT left over from the previous chain.
                    effects = effects.removingLUT()
                }
                // Derive the grain seed from the target clip so the same preset
                // applied to two clips does not produce identical procedural noise.
                effects = Self.seedingGrain(effects, for: id)
                track.clips[index].effects = effects
                pruneLUTDisplayNames()
                RenderCache.shared.invalidate(clipID: id)
                if let lut = preset.lut, lutBookmark == nil {
                    statusMessage = "Applied look preset \(preset.name); relink LUT \(lut.displayName)."
                } else {
                    statusMessage = "Applied look preset \(preset.name)."
                }
                scheduleRebuild()
                return
            }
        }
    }

    /// Mixes each grain node's preset seed with a per-clip seed so repeated
    /// presets do not share an identical grain pattern across clips.
    private static func seedingGrain(_ effects: [Effect], for id: Clip.ID) -> [Effect] {
        let clipSeed = grainSeed(for: id)
        return effects.map { effect in
            guard case .grain(var grain) = effect else { return effect }
            grain.seed ^= clipSeed
            return .grain(grain)
        }
    }

    /// Stable 64-bit seed derived from a clip's identifier (FNV-1a over the UUID).
    private static func grainSeed(for id: Clip.ID) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private var selectedVideoClipID: Clip.ID? {
        guard let id = selectedClipID,
              track(for: id)?.kind == .video else { return nil }
        return id
    }

    private func defaultLookPresetName(for clip: Clip) -> String {
        let mediaName = project.media(for: clip.mediaID)?.name ?? "Clip"
        let stem = (mediaName as NSString).deletingPathExtension
        let base = stem.isEmpty ? "Clip" : stem
        return "\(base) Look"
    }

    nonisolated static func resolvePresetLUT(_ reference: LookPresetLUTReference?, sourceURL: URL?) -> Data? {
        guard let reference, let sourceURL else { return nil }
        guard isSafeLookPresetLUTPath(reference.relativePath) else { return nil }
        let directoryURL = sourceURL.deletingLastPathComponent()
        let lutURL = directoryURL.appendingPathComponent(reference.relativePath)
        let didAccessPreset = sourceURL.startAccessingSecurityScopedResource()
        let didAccessDirectory = directoryURL.startAccessingSecurityScopedResource()
        let didAccessLUT = lutURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessLUT { lutURL.stopAccessingSecurityScopedResource() }
            if didAccessDirectory { directoryURL.stopAccessingSecurityScopedResource() }
            if didAccessPreset { sourceURL.stopAccessingSecurityScopedResource() }
        }
        guard FileManager.default.isReadableFile(atPath: lutURL.path),
              let bookmark = try? lutURL.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else {
            return nil
        }
        return bookmark
    }

    nonisolated static func isSafeLookPresetLUTPath(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("..") else {
            return false
        }
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count == 3,
              components[0] == "assets",
              components[1] == "luts",
              !components[2].isEmpty,
              components[2] != ".",
              components[2] != ".." else {
            return false
        }
        return (components[2] as NSString).pathExtension.lowercased() == "cube"
    }

    // MARK: - Look strength keyframes

    /// Source-local playhead time, or nil when the playhead is outside the selected
    /// clip — mirrors the speed and skin-smoothing keyframe behaviour so authoring
    /// a clip-local look keyframe is never ambiguous under time remapping.
    var selectedClipLookLocalPlayheadTime: CMTime? {
        selectedClipSourceLocalPlayheadTime
    }

    private func selectedClipLookStrength(_ kind: LookEffectKind) -> Keyframed<Float> {
        if let effect = selectedClip?.effects.first(where: { $0.lookKind == kind }),
           let track = effect.lookStrength {
            return track
        }
        return Keyframed(defaultValue: 0)
    }

    func lookStrengthKeyframes(_ kind: LookEffectKind) -> [Keyframe<Float>] {
        selectedClipLookStrength(kind).keyframes
    }

    func lookStrengthAtPlayhead(_ kind: LookEffectKind) -> Float {
        let track = selectedClipLookStrength(kind)
        guard let time = selectedClipLookLocalPlayheadTime else { return track.defaultValue }
        return track.value(at: time)
    }

    func lookStrengthKeyframeAtPlayhead(_ kind: LookEffectKind) -> Keyframe<Float>? {
        guard let time = selectedClipLookLocalPlayheadTime else { return nil }
        return nearestLookKeyframe(kind, to: time)
    }

    func addOrUpdateLookStrengthKeyframe(_ kind: LookEffectKind) {
        guard let id = selectedVideoClipID,
              let localTime = selectedClipLookLocalPlayheadTime else {
            statusMessage = "Move the playhead over the selected clip to add a keyframe."
            return
        }
        let existingID = lookStrengthKeyframeAtPlayhead(kind)?.id
        let value = selectedClipLookStrength(kind).defaultValue
        performUndoable(existingID == nil ? "Add \(kind.displayName) Keyframe"
                                          : "Update \(kind.displayName) Keyframe") {
            mutateLookStrength(kind, clipID: id) { track in
                if let existingID {
                    track.updateKeyframe(id: existingID, time: localTime, value: value)
                } else {
                    track.addKeyframe(at: localTime, value: value)
                }
            }
            statusMessage = "\(kind.displayName) keyframe set at \(TimeFormatting.timecode(localTime.seconds))."
        }
    }

    func removeLookStrengthKeyframe(_ kind: LookEffectKind) {
        guard let id = selectedVideoClipID,
              let keyframe = lookStrengthKeyframeAtPlayhead(kind) else {
            statusMessage = "No \(kind.displayName.lowercased()) keyframe at the playhead."
            return
        }
        performUndoable("Remove \(kind.displayName) Keyframe") {
            mutateLookStrength(kind, clipID: id) { track in
                track.removeKeyframe(id: keyframe.id)
            }
            statusMessage = "Removed \(kind.displayName.lowercased()) keyframe."
        }
    }

    func seekToPreviousLookStrengthKeyframe(_ kind: LookEffectKind) {
        guard let clip = selectedClip,
              let localTime = selectedClipLookLocalPlayheadTime else { return }
        let tolerance = lookKeyframeHitToleranceSeconds
        guard let previous = selectedClipLookStrength(kind).keyframes.last(where: {
            $0.time.seconds < localTime.seconds - tolerance
        }) else { return }
        let outputOffset = clip.outputOffset(forSourceOffset: previous.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    func seekToNextLookStrengthKeyframe(_ kind: LookEffectKind) {
        guard let clip = selectedClip,
              let localTime = selectedClipLookLocalPlayheadTime else { return }
        let tolerance = lookKeyframeHitToleranceSeconds
        guard let next = selectedClipLookStrength(kind).keyframes.first(where: {
            $0.time.seconds > localTime.seconds + tolerance
        }) else { return }
        let outputOffset = clip.outputOffset(forSourceOffset: next.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    private var lookKeyframeHitToleranceSeconds: Double {
        0.5 / max(1, project.frameRate)
    }

    private func nearestLookKeyframe(_ kind: LookEffectKind, to time: CMTime) -> Keyframe<Float>? {
        let tolerance = lookKeyframeHitToleranceSeconds
        return selectedClipLookStrength(kind).keyframes
            .map { keyframe in (keyframe, abs((keyframe.time - time).seconds)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func mutateLookStrength(_ kind: LookEffectKind, clipID: Clip.ID,
                                    _ transform: (inout Keyframed<Float>) -> Void) {
        for track in project.videoTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == clipID }) else { continue }
            // Reuse the existing look node if present, otherwise start from a
            // neutral one so a keyframe can be authored before the slider is touched.
            var effect = track.clips[index].effects.first { $0.lookKind == kind }
                ?? Self.neutralLookEffect(kind)
            guard var strength = effect.lookStrength else { return }
            transform(&strength)
            effect = effect.settingLookStrength(strength)
            // replacingLookEffect keeps the stored chain in canonical look order.
            track.clips[index].effects = track.clips[index].effects.replacingLookEffect(effect)
            RenderCache.shared.invalidate(clipID: clipID)
            scheduleRebuild()
            return
        }
    }

    private static func neutralLookEffect(_ kind: LookEffectKind) -> Effect {
        switch kind {
        case .grain: .grain(.neutral)
        case .halation: .halation(.neutral)
        case .vignette: .vignette(.neutral)
        }
    }
}
