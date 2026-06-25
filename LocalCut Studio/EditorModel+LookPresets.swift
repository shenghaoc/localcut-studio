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
        applyLookPreset(preset, sourceURL: nil)
    }

    func importLookPreset(url: URL) {
        guard selectedVideoClipID != nil else {
            statusMessage = "Select a video clip before importing a look preset."
            return
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let preset = try LookPresetV1(data: data)
            applyLookPreset(preset, sourceURL: url)
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
        do {
            try preset.encoded().write(to: url, options: [.atomic])
            statusMessage = "Exported look preset \(url.lastPathComponent)."
        } catch {
            statusMessage = "Could not export \(url.lastPathComponent)."
        }
    }

    private func applyLookPreset(_ preset: LookPresetV1, sourceURL: URL?) {
        guard let id = selectedVideoClipID else {
            statusMessage = "Select a video clip before applying a look preset."
            return
        }

        let lutBookmark = resolvePresetLUT(preset.lut, sourceURL: sourceURL)
        performUndoable("Apply Look Preset") {
            for track in project.videoTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                var effects = preset.applying(to: track.clips[index].effects)
                if let lutBookmark {
                    effects = effects.replacingLUT(bookmark: lutBookmark)
                }
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

    private func resolvePresetLUT(_ reference: LookPresetLUTReference?, sourceURL: URL?) -> Data? {
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
