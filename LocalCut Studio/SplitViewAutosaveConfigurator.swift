import AppKit
import SwiftUI

struct SplitViewAutosaveConfigurator: NSViewRepresentable {
    let autosaveName: String
    let isVertical: Bool
    /// When false (e.g. the inspector rail is collapsed to its slim 44 pt
    /// strip), autosaving is suspended so the collapsed width isn't written over
    /// the saved expanded layout.
    var isEnabled: Bool = true

    func makeNSView(context: Context) -> ConfiguringView {
        ConfiguringView(autosaveName: autosaveName, isVertical: isVertical, isEnabled: isEnabled)
    }

    func updateNSView(_ nsView: ConfiguringView, context: Context) {
        nsView.autosaveName = autosaveName
        nsView.isVertical = isVertical
        nsView.isEnabled = isEnabled
        nsView.configureSplitView()
    }

    final class ConfiguringView: NSView {
        var autosaveName: String
        var isVertical: Bool
        var isEnabled: Bool

        init(autosaveName: String, isVertical: Bool, isEnabled: Bool) {
            self.autosaveName = autosaveName
            self.isVertical = isVertical
            self.isEnabled = isEnabled
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.configureSplitView()
            }
        }

        func configureSplitView() {
            guard let splitView = nearestSplitView(matchingVertical: isVertical) else { return }
            splitView.identifier = NSUserInterfaceItemIdentifier(autosaveName)
            // Suspend autosave while disabled so a transient collapsed divider
            // position isn't written over the saved expanded layout; the last
            // saved positions stay in defaults and restore when re-enabled.
            splitView.autosaveName = isEnabled ? NSSplitView.AutosaveName(autosaveName) : nil
        }

        private func nearestSplitView(matchingVertical vertical: Bool) -> NSSplitView? {
            var candidate = superview
            while let view = candidate {
                if let splitView = view as? NSSplitView, splitView.isVertical == vertical {
                    return splitView
                }
                candidate = view.superview
            }
            return nil
        }
    }
}
