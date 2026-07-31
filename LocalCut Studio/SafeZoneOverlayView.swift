import SwiftUI

struct SafeZoneOverlayView: View {
    let profile: SafeZoneProfile
    let renderSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let canvas = PreviewCanvasGeometry.canvasRect(
                container: proxy.size,
                renderSize: renderSize)
            Canvas { context, _ in
                // ⚡ Bolt: Batching all safe-zone regions into a single Path and issuing one
                // context.fill / context.stroke reduces O(N) core graphics calls to O(1).
                // It also fixes overlapping translucent fills compounding in alpha.
                var path = Path()
                for region in profile.regions {
                    guard let first = region.points.first else { continue }
                    path.move(to: PreviewCanvasGeometry.point(first, in: canvas))
                    for point in region.points.dropFirst() {
                        path.addLine(to: PreviewCanvasGeometry.point(point, in: canvas))
                    }
                    path.closeSubpath()
                }
                context.fill(path, with: .color(.red.opacity(0.18)))
                context.stroke(path, with: .color(.red.opacity(0.75)), lineWidth: 1.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
