import Foundation
import Testing
@testable import LocalCut_Studio

@Suite("User-facing failure messages")
struct UserFacingFailureTests {
    @Test("File importer keeps cancellation silent")
    func fileImporterCancellationIsSilent() {
        #expect(FileImporterErrorPresentation.statusMessage(
            summary: "Could not open event log",
            error: CancellationError(),
            recoverySuggestion: "Choose a readable JSON event log and try again.") == nil)

        let cocoaCancellation = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.userCancelled.rawValue)
        #expect(FileImporterErrorPresentation.statusMessage(
            summary: "Could not open event log",
            error: cocoaCancellation,
            recoverySuggestion: "Choose a readable JSON event log and try again.") == nil)

        let urlCancellation = NSError(
            domain: NSURLErrorDomain,
            code: URLError.Code.cancelled.rawValue)
        #expect(FileImporterErrorPresentation.statusMessage(
            summary: "Could not open event log",
            error: urlCancellation,
            recoverySuggestion: "Choose a readable JSON event log and try again.") == nil)
    }

    @Test("File importer surfaces real errors without double punctuation")
    func fileImporterSurfacesRealErrors() {
        let error = NSError(
            domain: "UserFacingFailureTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The selected file is unavailable."])

        #expect(FileImporterErrorPresentation.statusMessage(
            summary: "Could not open event log",
            error: error,
            recoverySuggestion: "Choose a readable JSON event log and try again.")
            == "Could not open event log: The selected file is unavailable. Choose a readable JSON event log and try again.")
    }

    @Test("Partial media import status is bounded")
    func partialMediaImportStatusIsBounded() {
        let failures = [
            "Could not import first.mov: The file is damaged. Choose another file.",
            "Could not import second.mov: The file is missing. Choose another file.",
            "Could not import third.mov: Permission was denied. Choose another file.",
        ]

        #expect(ImportService.combinedStatusMessage(
            successMessage: "Imported usable.mov.",
            failureMessages: failures)
            == "Imported usable.mov. Could not import first.mov: The file is damaged. Choose another file. 2 more files could not be imported.")
        #expect(ImportService.boundedFailureSummary(failures)
            == "Could not import first.mov: The file is damaged. Choose another file. 2 more files could not be imported.")
    }
}
