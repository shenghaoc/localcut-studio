import AppKit

@MainActor
final class RegionCapturePicker {
    private static var activeController: RegionCaptureWindowController?

    static func pickRegion(for target: CaptureTarget) async -> CaptureRegion? {
        guard activeController == nil,
              case .display(let displayID, let width, let height) = target,
              let screen = NSScreen.screen(withDisplayID: displayID) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let controller = RegionCaptureWindowController(
                screen: screen,
                displayID: displayID,
                displayPixelWidth: width,
                displayPixelHeight: height) { region in
                    activeController = nil
                    continuation.resume(returning: region)
                }
            activeController = controller
            controller.begin()
        }
    }
}

private final class RegionCaptureWindowController {
    private let panel: RegionCapturePanel
    private var keyMonitor: Any?
    private var completion: ((CaptureRegion?) -> Void)?

    init(screen: NSScreen,
         displayID: UInt32,
         displayPixelWidth: Int,
         displayPixelHeight: Int,
         completion: @escaping (CaptureRegion?) -> Void) {
        self.completion = completion
        let selectionView = RegionSelectionView(
            screenFrame: screen.frame,
            displayID: displayID,
            displayPixelWidth: displayPixelWidth,
            displayPixelHeight: displayPixelHeight)
        panel = RegionCapturePanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = selectionView

        selectionView.onComplete = { [weak self] region in
            self?.finish(region)
        }
        selectionView.onCancel = { [weak self] in
            self?.finish(nil)
        }
    }

    func begin() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.finish(nil)
                return nil
            }
            return event
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        if let selectionView = panel.contentView as? RegionSelectionView {
            panel.makeFirstResponder(selectionView)
        }
    }

    private func finish(_ region: CaptureRegion?) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel.close()
        completion(region)
    }
}

private final class RegionCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionSelectionView: NSView {
    var onComplete: ((CaptureRegion) -> Void)?
    var onCancel: (() -> Void)?

    private let screenFrame: CGRect
    private let displayID: UInt32
    private let displayPixelWidth: Int
    private let displayPixelHeight: Int
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    init(screenFrame: CGRect,
         displayID: UInt32,
         displayPixelWidth: Int,
         displayPixelHeight: Int) {
        self.screenFrame = screenFrame
        self.displayID = displayID
        self.displayPixelWidth = displayPixelWidth
        self.displayPixelHeight = displayPixelHeight
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let selectionRect,
              selectionRect.width >= 20,
              selectionRect.height >= 20 else {
            startPoint = nil
            currentPoint = nil
            needsDisplay = true
            return
        }
        let screenSelection = selectionRect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        guard let region = CaptureRegion(
            displayID: displayID,
            selectionInScreen: screenSelection,
            screenFrame: screenFrame,
            displayPixelWidth: displayPixelWidth,
            displayPixelHeight: displayPixelHeight) else {
            startPoint = nil
            currentPoint = nil
            needsDisplay = true
            return
        }
        onComplete?(region)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dimPath = NSBezierPath(rect: bounds)
        if let selectionRect {
            dimPath.append(NSBezierPath(rect: selectionRect))
            dimPath.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dimPath.fill()

        if let selectionRect {
            NSColor.controlAccentColor.setStroke()
            let stroke = NSBezierPath(roundedRect: selectionRect, xRadius: 3, yRadius: 3)
            stroke.lineWidth = 2
            stroke.stroke()
        }

        drawInstructionText()
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y))
    }

    private func drawInstructionText() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
                shadow.shadowBlurRadius = 4
                return shadow
            }(),
        ]
        let text = "Drag to select a capture region. Press Esc to cancel."
        let textRect = CGRect(x: bounds.minX + 40,
                              y: bounds.maxY - 84,
                              width: bounds.width - 80,
                              height: 40)
        text.draw(in: textRect, withAttributes: attributes)
    }
}

private extension NSScreen {
    static func screen(withDisplayID displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        }
    }
}
