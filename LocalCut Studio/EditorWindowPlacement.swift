import CoreGraphics

/// Pure placement policy for a newly created editor window. SwiftUI applies it
/// through the scene APIs, allowing macOS restoration to remain authoritative
/// for windows that the person has already positioned.
enum EditorWindowPlacement {
    static let preferredSize = CGSize(width: 1360, height: 860)
    static let minimumContentSize = CGSize(width: 920, height: 620)
    static let displayInset: CGFloat = 80

    static func fittedSize(idealSize: CGSize, visibleRect: CGRect) -> CGSize {
        let requested = CGSize(
            width: max(preferredSize.width, idealSize.width),
            height: max(preferredSize.height, idealSize.height)
        )
        let available = CGSize(
            width: max(1, visibleRect.width - displayInset),
            height: max(1, visibleRect.height - displayInset)
        )
        return CGSize(
            width: min(requested.width, available.width),
            height: min(requested.height, available.height)
        )
    }
}
