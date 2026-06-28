import Foundation
import CoreGraphics

/// Corner position for a picture-in-picture overlay.
nonisolated enum PiPCorner: String, Codable, Hashable, Sendable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// Size preset for a PiP overlay, expressed as a fraction of the canvas height.
nonisolated enum PiPSize: String, Codable, Hashable, Sendable, CaseIterable {
    case small
    case medium
    case large

    /// Fraction of the canvas height for this size.
    var heightFraction: CGFloat {
        switch self {
        case .small: 0.15
        case .medium: 0.22
        case .large: 0.30
        }
    }

    var displayName: String { rawValue.capitalized }
}

/// Mask shape for a PiP overlay.
nonisolated enum PiPMask: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case circle
    case roundedRect

    var displayName: String {
        switch self {
        case .none: "None"
        case .circle: "Circle"
        case .roundedRect: "Rounded"
        }
    }
}

/// A picture-in-picture layout preset for webcam overlays.
nonisolated struct PiPPreset: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(corner.rawValue)-\(size.rawValue)-\(mask.rawValue)" }
    var corner: PiPCorner
    var size: PiPSize
    var mask: PiPMask
    /// Inset from the canvas edge in points.
    var inset: CGFloat = 24

    var displayName: String {
        "\(size.displayName) \(mask.displayName) — \(cornerDisplayName)"
    }

    private var cornerDisplayName: String {
        switch corner {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    /// Standard presets offered in the PiP picker.
    static let standardPresets: [PiPPreset] = [
        PiPPreset(corner: .bottomRight, size: .small, mask: .circle),
        PiPPreset(corner: .bottomRight, size: .medium, mask: .roundedRect),
        PiPPreset(corner: .bottomLeft, size: .medium, mask: .roundedRect),
        PiPPreset(corner: .topRight, size: .small, mask: .circle),
        PiPPreset(corner: .bottomRight, size: .large, mask: .none),
    ]

    /// Compute the transform for a PiP layer given the canvas and source sizes.
    /// Returns (position, scale) where position is the top-left origin and scale
    /// is the uniform scale factor.
    func layout(canvasSize: CGSize, sourceSize: CGSize) -> (origin: CGPoint, scale: CGFloat) {
        let targetHeight = canvasSize.height * size.heightFraction
        let aspectRatio = sourceSize.width / max(1, sourceSize.height)
        let targetWidth = targetHeight * aspectRatio
        let scale = targetHeight / max(1, sourceSize.height)

        let x: CGFloat
        switch corner {
        case .topLeft, .bottomLeft:
            x = inset
        case .topRight, .bottomRight:
            x = canvasSize.width - targetWidth - inset
        }

        let y: CGFloat
        switch corner {
        case .topLeft, .topRight:
            y = inset
        case .bottomLeft, .bottomRight:
            y = canvasSize.height - targetHeight - inset
        }

        return (CGPoint(x: x, y: y), scale)
    }
}
