import Foundation
import AVFoundation
import LocalCutCore

/// Deprecated `@MainActor` convenience wrappers retained for test fixtures.
/// Production code routes through `EditorModel.importCaptionTrack(from:)`,
/// which offloads file IO + parsing to a detached task.
nonisolated enum CaptionImporterCompat {

    @available(*, deprecated, message: "Use EditorModel.importCaptionTrack(from:) or CaptionImporter.parseLines(data:isVTT:) on a detached task.")
    @MainActor
    static func importTrack(from url: URL, name: String? = nil) throws -> CaptionTrack {
        let data = try Data(contentsOf: url)
        let isVTT = url.pathExtension.lowercased() == "vtt"
        let lines = try CaptionImporter.parseLines(data: data, isVTT: isVTT)
        return CaptionTrack(
            name: name ?? url.deletingPathExtension().lastPathComponent,
            lines: lines)
    }

    @available(*, deprecated, message: "Use CaptionImporter.parseLines(data:isVTT:) and construct CaptionTrack(name:lines:) explicitly.")
    @MainActor
    static func importTrack(data: Data, isVTT: Bool, name: String) throws -> CaptionTrack {
        let lines = try CaptionImporter.parseLines(data: data, isVTT: isVTT)
        return CaptionTrack(name: name, lines: lines)
    }
}
