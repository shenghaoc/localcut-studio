import AppKit
import SwiftUI

struct SplitViewAutosaveConfigurator: NSViewRepresentable {
    let autosaveName: String
    let isVertical: Bool

    func makeNSView(context: Context) -> ConfiguringView {
        ConfiguringView(autosaveName: autosaveName, isVertical: isVertical)
    }

    func updateNSView(_ nsView: ConfiguringView, context: Context) {
        nsView.autosaveName = autosaveName
        nsView.isVertical = isVertical
        nsView.configureSplitView()
    }

    final class ConfiguringView: NSView {
        var autosaveName: String
        var isVertical: Bool

        init(autosaveName: String, isVertical: Bool) {
            self.autosaveName = autosaveName
            self.isVertical = isVertical
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
            splitView.autosaveName = NSSplitView.AutosaveName(autosaveName)
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
