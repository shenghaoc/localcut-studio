import AppKit
import CoreGraphics

nonisolated enum ScreencastEventMonitorSource: Equatable, Sendable {
    case ownAppLocal
    case globalTarget
}

nonisolated struct ScreencastEventCoordinateMapper {
    typealias ScreenFrameProvider = @Sendable (UInt32) -> CGRect?

    static func normalizedPosition(
        target: CaptureTarget,
        captureRegion: CaptureRegion?,
        monitorSource: ScreencastEventMonitorSource,
        screenLocation: CGPoint,
        locationInWindow: CGPoint,
        windowSize: CGSize?,
        screenFrameProvider: ScreenFrameProvider = Self.screenFrame
    ) -> CGPoint? {
        if monitorSource == .ownAppLocal {
            guard let size = windowSize else { return nil }
            return normalizedWindowPosition(location: locationInWindow, size: size)
        }

        switch target {
        case .display(let displayID, _, _):
            if let region = captureRegion, region.displayID == displayID {
                return normalizedRegionPosition(
                    region: region,
                    point: screenLocation,
                    screenFrameProvider: screenFrameProvider)
            }
            return normalizedScreenPosition(
                displayID: displayID,
                point: screenLocation,
                screenFrameProvider: screenFrameProvider)

        case .window(_, _, _, let width, let height, let frame):
            if !frame.isNull, !frame.isEmpty {
                return normalizedRectPosition(rect: frame, point: screenLocation)
            }
            return normalizedWindowPosition(
                location: locationInWindow,
                size: CGSize(width: CGFloat(width), height: CGFloat(height)))

        case .application(_, _, _, let displayID, _, _):
            if let region = captureRegion, region.displayID == displayID {
                return normalizedRegionPosition(
                    region: region,
                    point: screenLocation,
                    screenFrameProvider: screenFrameProvider)
            }
            return normalizedScreenPosition(
                displayID: displayID,
                point: screenLocation,
                screenFrameProvider: screenFrameProvider)
        }
    }

    static func screenFrame(for displayID: UInt32) -> CGRect? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        }?.frame
    }

    private static func normalizedWindowPosition(location: CGPoint, size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let clampedX = max(0, min(location.x, size.width))
        let clampedY = max(0, min(location.y, size.height))
        return CGPoint(x: clampedX / size.width, y: 1.0 - clampedY / size.height)
    }

    private static func normalizedScreenPosition(
        displayID: UInt32,
        point: CGPoint,
        screenFrameProvider: ScreenFrameProvider
    ) -> CGPoint? {
        guard let frame = screenFrameProvider(displayID) else { return nil }
        return normalizedRectPosition(rect: frame, point: point)
    }

    private static func normalizedRegionPosition(
        region: CaptureRegion,
        point: CGPoint,
        screenFrameProvider: ScreenFrameProvider
    ) -> CGPoint? {
        guard let screenFrame = screenFrameProvider(region.displayID) else { return nil }
        let regionRect = CGRect(
            x: screenFrame.minX + region.sourceRect.minX,
            y: screenFrame.maxY - region.sourceRect.maxY,
            width: region.sourceRect.width,
            height: region.sourceRect.height)
        return normalizedRectPosition(rect: regionRect, point: point)
    }

    private static func normalizedRectPosition(rect: CGRect, point: CGPoint) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width,
            y: 1.0 - (point.y - rect.minY) / rect.height)
    }
}
