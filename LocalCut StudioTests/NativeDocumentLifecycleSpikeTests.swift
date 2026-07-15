import Foundation
import SwiftUI
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import LocalCut_Studio

/// This is a compile-tested API probe, not the production persistence path.
/// It records the macOS 26 `ReferenceFileDocument` surface used to decide
/// whether a `DocumentGroup` migration could preserve LocalCut's URL-based
/// streaming bundle implementation.
@Suite("Native document lifecycle API spike")
struct NativeDocumentLifecycleSpikeTests {
    @Test func referenceFileDocumentAdvertisesFlatAndPackageTypes() throws {
        let document = NativeDocumentLifecycleAdapterSpike()
        #expect(NativeDocumentLifecycleAdapterSpike.readableContentTypes == [
            .nativeLifecycleFlatSpike,
            .nativeLifecycleBundleSpike
        ])
        #expect(try document.snapshot(contentType: .nativeLifecycleFlatSpike).isEmpty)
    }

    @MainActor
    @Test func interchangeRequestsCarryFileExporterTypesAndNames() throws {
        let model = EditorModel()
        model.project.name = "Lifecycle Test"
        // The request layer serializes the current model before SwiftUI presents
        // a destination; a nonzero duration reaches both existing serializers.
        model.totalDuration = 1

        let otio = try #require(model.makeOtioExportRequest())
        #expect(otio.contentType == .localCutOtioExport)
        #expect(otio.defaultFilename == "Lifecycle Test")
        #expect(!otio.document.data.isEmpty)

        let edl = try #require(model.makeEdlExportRequest(trackIndex: 0))
        #expect(edl.contentType == .localCutEdlExport)
        #expect(edl.defaultFilename == "Lifecycle Test")
        #expect(!edl.document.data.isEmpty)
    }
}

extension UTType {
    nonisolated static let nativeLifecycleFlatSpike = UTType(exportedAs: "com.localcut.spike.lcstudio")
    nonisolated static let nativeLifecycleBundleSpike = UTType(exportedAs: "com.localcut.spike.lcbundle")
}

/// `ReferenceFileDocument` has synchronous read/write callbacks on macOS 26.
/// The `Mutex` merely makes this test adapter meet the protocol's Sendable
/// contract; it intentionally does not attempt production streaming I/O.
nonisolated final class NativeDocumentLifecycleAdapterSpike: @unchecked Sendable, ReferenceFileDocument {
    typealias Snapshot = Data

    nonisolated static var readableContentTypes: [UTType] {
        [.nativeLifecycleFlatSpike, .nativeLifecycleBundleSpike]
    }

    nonisolated static var writableContentTypes: [UTType] {
        [.nativeLifecycleFlatSpike, .nativeLifecycleBundleSpike]
    }

    private let payload: Mutex<Data>

    nonisolated init() {
        payload = Mutex(Data())
    }

    nonisolated required init(configuration: ReadConfiguration) throws {
        let data: Data
        if configuration.contentType == .nativeLifecycleBundleSpike {
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
        if configuration.contentType == .nativeLifecycleBundleSpike {
            return FileWrapper(directoryWithFileWrappers: [
                "project.lcstudio": FileWrapper(regularFileWithContents: snapshot)
            ])
        }
        return FileWrapper(regularFileWithContents: snapshot)
    }
}

/// This generic helper is compiled with the test target to prove the adapter
/// reaches the macOS 26 `DocumentGroup` overload without adopting it in the
/// app scene.
private func nativeDocumentGroupSpike() -> some Scene {
    DocumentGroup(newDocument: { NativeDocumentLifecycleAdapterSpike() }) { _ in
        Text("Native document lifecycle spike")
    }
}
