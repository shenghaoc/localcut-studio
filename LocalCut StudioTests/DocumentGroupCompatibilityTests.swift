import Foundation
import SwiftUI
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import LocalCut_Studio

/// Compile-tested probe of macOS 26 `ReferenceFileDocument` / `DocumentGroup`
/// surface area. This does **not** prove production package I/O equivalence;
/// it only records that both flat and package content types can be advertised
/// and that the scene initializer accepts the adapter type.
@Suite("DocumentGroup compatibility")
struct DocumentGroupCompatibilityTests {
    @Test func referenceFileDocumentAdvertisesFlatAndPackageTypes() throws {
        let document = DocumentGroupCompatibilityAdapter()
        #expect(DocumentGroupCompatibilityAdapter.readableContentTypes == [
            .documentGroupCompatibilityFlat,
            .documentGroupCompatibilityBundle
        ])
        #expect(try document.snapshot(contentType: .documentGroupCompatibilityFlat).isEmpty)
    }
}

extension UTType {
    nonisolated static let documentGroupCompatibilityFlat = UTType(exportedAs: "com.localcut.compat.lcstudio")
    nonisolated static let documentGroupCompatibilityBundle = UTType(exportedAs: "com.localcut.compat.lcbundle")
}

/// `ReferenceFileDocument` has synchronous read/write callbacks on macOS 26.
/// The `Mutex` merely makes this test adapter meet the protocol's Sendable
/// contract; it intentionally does not attempt production package I/O.
nonisolated final class DocumentGroupCompatibilityAdapter: @unchecked Sendable, ReferenceFileDocument {
    typealias Snapshot = Data

    nonisolated static var readableContentTypes: [UTType] {
        [.documentGroupCompatibilityFlat, .documentGroupCompatibilityBundle]
    }

    nonisolated static var writableContentTypes: [UTType] {
        [.documentGroupCompatibilityFlat, .documentGroupCompatibilityBundle]
    }

    private let payload: Mutex<Data>

    nonisolated init() {
        payload = Mutex(Data())
    }

    nonisolated required init(configuration: ReadConfiguration) throws {
        let data: Data
        if configuration.contentType == .documentGroupCompatibilityBundle {
            data = configuration.file.fileWrappers?["project.lcstudio"]?.regularFileContents ?? Data()
        } else {
            data = configuration.file.regularFileContents ?? Data()
        }
        payload = Mutex(data)
    }

    nonisolated func snapshot(contentType: UTType) throws -> Data {
        payload.withLock { $0 }
    }

    nonisolated func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        if configuration.contentType == .documentGroupCompatibilityBundle {
            return FileWrapper(directoryWithFileWrappers: [
                "project.lcstudio": FileWrapper(regularFileWithContents: snapshot)
            ])
        }
        return FileWrapper(regularFileWithContents: snapshot)
    }
}

/// Compiled with the test target to prove the adapter reaches the macOS 26
/// `DocumentGroup` overload without adopting it in the app scene.
private func documentGroupCompatibilityScene() -> some Scene {
    DocumentGroup(newDocument: { DocumentGroupCompatibilityAdapter() }) { _ in
        Text("DocumentGroup compatibility probe")
    }
}
