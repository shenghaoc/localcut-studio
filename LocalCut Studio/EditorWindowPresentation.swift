import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Window-scoped presentation bindings exposed to menu commands. The focused
/// binding follows the key window, so a View-menu action cannot change another
/// editor window's inspector state.
private struct InspectorVisibilityFocusedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct InterchangeExportFocusedKey: FocusedValueKey {
    typealias Value = InterchangeExportAction
}

private struct TimelineDurationFocusedKey: FocusedValueKey {
    typealias Value = Double
}

extension FocusedValues {
    var localCutInspectorVisibility: Binding<Bool>? {
        get { self[InspectorVisibilityFocusedKey.self] }
        set { self[InspectorVisibilityFocusedKey.self] = newValue }
    }

    var localCutInterchangeExport: InterchangeExportAction? {
        get { self[InterchangeExportFocusedKey.self] }
        set { self[InterchangeExportFocusedKey.self] = newValue }
    }

    var localCutTimelineDuration: Double? {
        get { self[TimelineDurationFocusedKey.self] }
        set { self[TimelineDurationFocusedKey.self] = newValue }
    }
}

/// A focused window action keeps File-menu interchange exports attached to the
/// key editor scene instead of making a process-global panel owner.
struct InterchangeExportAction {
    let run: @MainActor (InterchangeExportKind) -> Void

    @MainActor
    func callAsFunction(_ kind: InterchangeExportKind) {
        run(kind)
    }
}

enum InterchangeExportKind {
    case otio
    case edl
}

extension UTType {
    /// Dynamic types preserve the requested extension without adding a new
    /// document UTI declaration: OTIO and EDL are generated sidecars, not
    /// LocalCut project documents.
    nonisolated static let localCutOtioExport = UTType(filenameExtension: "otio") ?? .json
    nonisolated static let localCutEdlExport = UTType(filenameExtension: "edl") ?? .plainText
}

/// A small, in-memory document for SwiftUI's file exporter. Timeline
/// interchange is already fully serialized before presentation, unlike a
/// queued AVFoundation render that must retain the `NSSavePanel` flow.
struct InterchangeExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.localCutOtioExport, .localCutEdlExport]
    }

    let data: Data

    init(contents: String) {
        data = Data(contents.utf8)
    }

    init(configuration: FileDocumentReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: FileDocumentWriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct InterchangeExportRequest: Identifiable {
    let id = UUID()
    let document: InterchangeExportDocument
    let contentType: UTType
    /// A stem for SwiftUI's `fileExporter`; the exporter appends the extension
    /// advertised by `contentType`.
    let defaultFilename: String
    let warningSummary: String?

    func completedMessage(at url: URL) -> String {
        if let warningSummary {
            String(localized: "Exported \(url.lastPathComponent) — \(warningSummary)")
        } else {
            String(localized: "Exported \(url.lastPathComponent).")
        }
    }
}

/// Formats interchange-export failures while treating an explicit panel
/// dismissal as a normal, silent outcome.
enum InterchangeExportErrorPresentation {
    nonisolated static func statusMessage(for error: Error) -> String? {
        guard !UserCancellation.isCancellation(error) else { return nil }
        return String(localized: "Interchange export failed: \(error.localizedDescription)")
    }
}
