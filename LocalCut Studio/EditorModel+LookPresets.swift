import Foundation
import AppKit
import UniformTypeIdentifiers
import LocalCutCore

extension UTType {
    static let localCutLookPreset = UTType(filenameExtension: LookPresetV1.fileExtension,
                                          conformingTo: .json) ?? .json
}

extension EditorModel {
    // MARK: - Look effects

    var selectedClipHasLookEffects: Bool {
        selectedClip?.effects.hasLookEffects ?? false
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
        let preset = LookPresetV1(name: defaultLookPresetName(for: clip),
                                  effects: clip.effects)
        guard !preset.nodes.isEmpty else {
            statusMessage = "The selected clip has no look effects to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.localCutLookPreset]
        panel.nameFieldStringValue = "\(preset.name).\(LookPresetV1.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportLookPreset(preset, to: url)
    }

    func exportLookPreset(to url: URL) {
        guard let clip = selectedClip,
              selectedVideoClipID != nil else {
            statusMessage = "Select a video clip before exporting a look preset."
            return
        }
        exportLookPreset(LookPresetV1(name: defaultLookPresetName(for: clip),
                                      effects: clip.effects),
                         to: url)
    }

    private func exportLookPreset(_ preset: LookPresetV1, to url: URL) {
        guard !preset.nodes.isEmpty else {
            statusMessage = "The selected clip has no look effects to export."
            return
        }
        Task {
            do {
                // Encode is cheap, but the disk write can stall on a slow network
                // share or iCloud Drive, so push it off the main actor.
                let data = try preset.encoded()
                try await Task.detached {
                    try data.write(to: url, options: [.atomic])
                }.value
                statusMessage = "Exported look preset \(url.lastPathComponent)."
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
        let lutURL = sourceURL.deletingLastPathComponent().appendingPathComponent(reference.relativePath)
        let didAccess = lutURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { lutURL.stopAccessingSecurityScopedResource() }
        }
        guard FileManager.default.fileExists(atPath: lutURL.path),
              let bookmark = try? lutURL.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else {
            return nil
        }
        return bookmark
    }
}
