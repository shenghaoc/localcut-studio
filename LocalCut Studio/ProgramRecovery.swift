import Foundation
import CoreMedia
import LocalCutCore

// MARK: - Program recovery

/// Handles recovery of Program Mode sessions from crash-left manifests.
/// Reuses the Phase 41 recovery surface (`CaptureCoordinator.scanRecoveredSessions`)
/// and extends it with layout-track reconstruction from scene-switch records.
enum ProgramRecovery: Sendable {

    /// Checks whether a recovered manifest contains Program Mode data
    /// (scene-doc or scene-switch records).
    static func hasProgramData(manifest: CaptureManifest) -> Bool {
        !manifest.sceneDocRecords.isEmpty || !manifest.sceneSwitchRecords.isEmpty
    }

    /// Reconstructs layout track data from a recovered manifest.
    /// Uses the latest preceding scene-doc snapshot for each scene-switch,
    /// NEVER the user's current scenes (which may have been edited after
    /// the crash).
    ///
    /// Returns nil if the manifest has no scene-switch records.
    static func reconstructLayout(
        manifest: CaptureManifest,
        sessionDuration: CMTime
    ) -> [LayoutClip]? {
        let resolved = manifest.resolvedSceneSwitches
        guard !resolved.isEmpty else { return nil }

        return ProgramLanding.buildLayoutClips(
            switches: resolved,
            sessionStartHostTimeUs: manifest.header?.sessionStartHostTimeUs ?? 0,
            sessionDuration: sessionDuration)
    }

    /// Reconstructs the full recovery result: ISO track URLs + layout
    /// track clips.
    ///
    /// - Parameters:
    ///   - result: The recovered capture session result.
    ///   - rootURL: The recordings root directory.
    /// - Returns: A `ProgramRecoveryResult` if recovery is possible, nil otherwise.
    static func recover(
        from result: CaptureSessionResult,
        rootURL: URL
    ) -> ProgramRecoveryResult? {
        let manifest = result.manifest
        guard hasProgramData(manifest: manifest) else { return nil }

        // Compute session duration from the manifest.
        let duration: CMTime
        if let finalize = manifest.finalize {
            duration = CaptureManifest.time(fromMicroseconds: finalize.durationUs)
        } else if let header = manifest.header {
            // Unfinalized — estimate from the latest source-ended record.
            let maxEndUs = manifest.records.compactMap { record -> Int64? in
                if case .sourceEnded(let ended) = record { return ended.atUs }
                return nil
            }.max() ?? 0
            let durationUs = maxEndUs - header.sessionStartHostTimeUs
            duration = CaptureManifest.time(fromMicroseconds: max(0, durationUs))
        } else {
            return nil
        }

        // Build ISO track URLs.
        let sessionURL = result.directoryURL
        var isoURLs: [UUID: URL] = [:]
        for source in manifest.header?.sources ?? [] {
            let fileURL = sessionURL.appendingPathComponent(source.relativePath)
            if FileManager.default.isReadableFile(atPath: fileURL.path) {
                isoURLs[source.id] = fileURL
            }
        }

        // Reconstruct layout clips from scene-switch records.
        let layoutClips = reconstructLayout(manifest: manifest, sessionDuration: duration)

        // Build recovery issues for missing scenes.
        var issues: [ProgramRecoveryIssue] = []
        let resolved = manifest.resolvedSceneSwitches
        for sw in resolved {
            let sceneExists = sw.sceneDoc.scenes.contains(where: { $0.id == sw.sceneId })
            if !sceneExists {
                issues.append(.unresolvableScene(sceneId: sw.sceneId, atUs: sw.atUs))
            }
        }

        return ProgramRecoveryResult(
            sessionResult: result,
            isoTrackURLs: isoURLs,
            layoutClips: layoutClips ?? [],
            duration: duration,
            issues: issues)
    }
}

// MARK: - Recovery result

struct ProgramRecoveryResult: Sendable {
    let sessionResult: CaptureSessionResult
    let isoTrackURLs: [UUID: URL]
    let layoutClips: [LayoutClip]
    let duration: CMTime
    let issues: [ProgramRecoveryIssue]
}

// MARK: - Recovery issue

enum ProgramRecoveryIssue: Sendable, Hashable, LocalizedError {
    /// A scene-switch referenced a scene ID not found in the preceding
    /// scene-doc snapshot. The layout clip gets a placeholder scene.
    case unresolvableScene(sceneId: UUID, atUs: Int64)

    var errorDescription: String? {
        switch self {
        case .unresolvableScene(let sceneId, _):
            "Scene \(sceneId.uuidString.prefix(8)) could not be resolved from manifest."
        }
    }
}
