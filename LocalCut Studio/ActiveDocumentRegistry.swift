import Foundation

/// Tracks the editor window that most recently became active without making an
/// App Intent depend on a process-wide editor model. The registry is deliberately
/// small: document lifetime remains owned by SwiftUI/the document controller,
/// while this object only supplies focused routing for system actions.
@MainActor
final class ActiveDocumentRegistry {
    struct Token: Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    struct Target {
        let token: Token
        let model: EditorModel
    }

    private final class WeakEditor {
        weak var model: EditorModel?

        init(_ model: EditorModel) {
            self.model = model
        }
    }

    private var editors: [Token: WeakEditor] = [:]
    private var tokensByEditor: [ObjectIdentifier: Token] = [:]
    private var mostRecentlyActive: Token?
    private var recency: [Token] = []

    /// Registers a document window's model. Re-registering the same model keeps
    /// its token stable, which makes a queued App Intent safe to validate before
    /// it runs.
    @discardableResult
    func register(_ model: EditorModel) -> Token {
        removeReleasedEditors()
        let identity = ObjectIdentifier(model)
        if let token = tokensByEditor[identity], editors[token]?.model === model {
            activate(token)
            return token
        }

        let token = Token(rawValue: UUID())
        editors[token] = WeakEditor(model)
        tokensByEditor[identity] = token
        activate(token)
        return token
    }

    /// Marks a window as active when it becomes key. Calling this for an
    /// unregistered model is intentionally equivalent to registration so the
    /// view lifecycle stays resilient to SwiftUI reconstruction.
    func activate(_ model: EditorModel) {
        register(model)
    }

    /// Removes a closed document from routing. A queued intent that captured its
    /// token will then fail with `targetDocumentClosed` instead of mutating
    /// another, newer window.
    func unregister(_ model: EditorModel) {
        let identity = ObjectIdentifier(model)
        guard let token = tokensByEditor.removeValue(forKey: identity) else { return }
        editors.removeValue(forKey: token)
        recency.removeAll { $0 == token }
        if mostRecentlyActive == token {
            mostRecentlyActive = recency.last
        }
    }

    /// Captures the currently focused (or most recently active) document for an
    /// incoming action. The caller later validates the same token before it runs.
    func activeTarget() -> Target? {
        removeReleasedEditors()
        if let mostRecentlyActive,
           let model = editors[mostRecentlyActive]?.model {
            return Target(token: mostRecentlyActive, model: model)
        }
        guard let token = recency.last,
              let model = editors[token]?.model else {
            return nil
        }
        mostRecentlyActive = token
        return Target(token: token, model: model)
    }

    /// Resolves an already-captured target. It returns `nil` after that document
    /// has closed, rather than silently retargeting the action to another window.
    func model(for token: Token) -> EditorModel? {
        removeReleasedEditors()
        return editors[token]?.model
    }

    private func activate(_ token: Token) {
        guard editors[token]?.model != nil else { return }
        recency.removeAll { $0 == token }
        recency.append(token)
        mostRecentlyActive = token
    }

    private func removeReleasedEditors() {
        let released = editors.compactMap { token, editor in
            editor.model == nil ? token : nil
        }
        for token in released {
            editors.removeValue(forKey: token)
            recency.removeAll { $0 == token }
        }
        tokensByEditor = tokensByEditor.filter { _, token in editors[token]?.model != nil }
        if let mostRecentlyActive, editors[mostRecentlyActive]?.model == nil {
            self.mostRecentlyActive = recency.last
        }
    }
}
