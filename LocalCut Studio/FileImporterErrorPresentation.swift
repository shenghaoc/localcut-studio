import Foundation

/// Identifies expected user-driven dismissal errors from system file panels.
enum UserCancellation {
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let cocoaError = error as NSError
        return (cocoaError.domain == NSCocoaErrorDomain
                && cocoaError.code == CocoaError.Code.userCancelled.rawValue)
            || (cocoaError.domain == NSURLErrorDomain
                && cocoaError.code == URLError.Code.cancelled.rawValue)
    }
}

/// Converts file-importer failures into actionable status copy while treating
/// user cancellation as a normal, silent dismissal.
enum FileImporterErrorPresentation {
    nonisolated static func statusMessage(
        summary: String,
        error: Error,
        recoverySuggestion: String
    ) -> String? {
        guard !UserCancellation.isCancellation(error) else { return nil }
        return EditorModel.failureStatusMessage(
            summary: summary,
            detail: error.localizedDescription,
            recoverySuggestion: recoverySuggestion)
    }
}
