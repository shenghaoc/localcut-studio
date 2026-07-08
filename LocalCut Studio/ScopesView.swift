import SwiftUI
import LocalCutCore

/// One of the scope panels the user can switch between.
enum ScopeKind: String, CaseIterable, Identifiable, Sendable {
    case waveform
    case vectorscope

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waveform: "Waveform"
        case .vectorscope: "Vectorscope"
        }
    }
}

/// The scopes panel: a `Picker` over scope kinds plus a `Canvas` drawing the
/// latest sample published by `ScopeSampler.shared`.
///
/// The sampler is nonisolated (the compositor writes to it from off-main),
/// so the view polls the sampler revision and only invalidates SwiftUI state
/// when a new sample lands. The task flips `enabled` so a hidden panel pays no
/// per-frame cost in the compositor's hot path.
struct ScopesView: View {
    let sampler: ScopeSampler
    @State private var kind: ScopeKind = .waveform
    @State private var latest: ScopeSample?
    @State private var displayedRevision: Int = -1

    private static let refreshNanoseconds = UInt64(ScopeSampler.minIntervalSeconds * 1_000_000_000)
    private let vectorscopeTargets: [(label: String, rgb: (r: Float, g: Float, b: Float), color: Color)] = [
        ("Yl", (0.75, 0.75, 0.0), .yellow),
        ("R", (0.75, 0.0, 0.0), .red),
        ("Mg", (0.75, 0.0, 0.75), .purple),
        ("B", (0.0, 0.0, 0.75), .blue),
        ("Cy", (0.0, 0.75, 0.75), .cyan),
        ("G", (0.0, 0.75, 0.0), .green),
    ]

    init(sampler: ScopeSampler = .shared) {
        self.sampler = sampler
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("", selection: $kind) {
                    ForEach(ScopeKind.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Scope kind")
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Canvas { context, size in
                switch kind {
                case .waveform:
                    drawWaveform(into: context, size: size, sample: latest)
                case .vectorscope:
                    drawVectorscope(into: context, size: size, sample: latest)
                }
            }
            .background(Color.black)
            .cornerRadius(4)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .accessibilityLabel(kind == .waveform ? "Waveform scope" : "Vectorscope")
            .accessibilityValue(latest == nil ? "No frames yet" : "Live")
        }
        .frame(minWidth: 200, idealWidth: 240, minHeight: 160, idealHeight: 220)
        // Scopes are a content readout, not chrome — sit them on the recessed
        // content surface (matching the timeline lanes) rather than a sidebar
        // material that would read as window chrome.
        .background(Color.lcLane)
        .task { await refreshSamplesUntilCancelled() }
    }

    @MainActor
    private func refreshSamplesUntilCancelled() async {
        sampler.setEnabled(true)
        refreshSnapshotIfNeeded()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.refreshNanoseconds)
            } catch {
                break
            }
            refreshSnapshotIfNeeded()
        }
        sampler.setEnabled(false)
    }

    @MainActor
    private func refreshSnapshotIfNeeded() {
        let snapshot = sampler.snapshot
        guard snapshot.revision != displayedRevision else { return }
        latest = snapshot.sample
        displayedRevision = snapshot.revision
    }

    // MARK: - Waveform

    private func drawWaveform(into context: GraphicsContext, size: CGSize, sample: ScopeSample?) {
        // Frame outline.
        let frameRect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        context.stroke(Path(frameRect), with: .color(.white.opacity(0.15)), lineWidth: 0.5)
        drawWaveformGraticule(into: context, frameRect: frameRect)

        guard let sample, !sample.waveform.isEmpty else {
            placeholder(into: context, size: size, label: "No frames yet")
            return
        }

        // Each column's bins are drawn vertically: bin index 0 → bottom, last → top.
        // The bin's normalised intensity (0…1) drives both opacity and width.
        let columnSpacing = frameRect.width / CGFloat(sample.waveform.count)
        for column in sample.waveform {
            let colX = frameRect.minX + CGFloat(column.x) * frameRect.width
            for (binIndex, value) in column.bins.enumerated() where value > 0.02 {
                let normY = CGFloat(binIndex) / CGFloat(max(1, column.bins.count - 1))
                let y = frameRect.maxY - normY * frameRect.height
                let dot = CGRect(
                    x: colX - columnSpacing / 2,
                    y: y - 1,
                    width: columnSpacing,
                    height: 2)
                context.fill(Path(dot), with: .color(.green.opacity(Double(value))))
            }
        }
    }

    /// Horizontal IRE reference lines (0/25/50/75/100) with small labels so luma
    /// levels read against a scale instead of empty black. Static — drawn behind
    /// the live trace, no per-frame sampling cost.
    private func drawWaveformGraticule(into context: GraphicsContext, frameRect: CGRect) {
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = frameRect.maxY - CGFloat(fraction) * frameRect.height
            var line = Path()
            line.move(to: CGPoint(x: frameRect.minX, y: y))
            line.addLine(to: CGPoint(x: frameRect.maxX, y: y))
            context.stroke(line, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            // Sit the label just above its line (bottom-leading) so the line
            // never bisects the digits; nudge the top "100" down a touch so it
            // isn't clipped at the frame's top edge.
            let label = Text("\(Int(fraction * 100))")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.35))
            let labelY = max(y, frameRect.minY + 9)
            context.draw(label, at: CGPoint(x: frameRect.minX + 4, y: labelY), anchor: .bottomLeading)
        }
    }

    // MARK: - Vectorscope

    private func drawVectorscope(into context: GraphicsContext, size: CGSize, sample: ScopeSample?) {
        let frameRect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let plotSide = min(frameRect.width, frameRect.height)
        let plot = CGRect(x: frameRect.midX - plotSide / 2,
                          y: frameRect.midY - plotSide / 2,
                          width: plotSide, height: plotSide)

        // Outer chroma circle + a 75%-saturation reference ring (colour-bar
        // targets sit on/near it) + crosshairs as a reference grid.
        context.stroke(Path(ellipseIn: plot), with: .color(.white.opacity(0.2)), lineWidth: 0.5)
        let inner = plot.insetBy(dx: plot.width * 0.125, dy: plot.height * 0.125)
        context.stroke(Path(ellipseIn: inner), with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        var crosshair = Path()
        crosshair.move(to: CGPoint(x: plot.midX, y: plot.minY))
        crosshair.addLine(to: CGPoint(x: plot.midX, y: plot.maxY))
        crosshair.move(to: CGPoint(x: plot.minX, y: plot.midY))
        crosshair.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        context.stroke(crosshair, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
        drawVectorscopeTargets(into: context, plot: plot)

        guard let sample, !sample.vectorscope.isEmpty else {
            placeholder(into: context, size: size, label: "No frames yet")
            return
        }

        for point in sample.vectorscope {
            let center = vectorscopePoint(point, in: plot)
            let dot = CGRect(x: center.x - 0.75, y: center.y - 0.75, width: 1.5, height: 1.5)
            context.fill(Path(ellipseIn: dot), with: .color(.green.opacity(0.45)))
        }
    }

    private func drawVectorscopeTargets(into context: GraphicsContext, plot: CGRect) {
        for target in vectorscopeTargets {
            let uv = ScopeSampler.rgbToUV(target.rgb)
            let center = vectorscopePoint(VectorPoint(u: uv.u, v: uv.v), in: plot)
            let box = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            context.stroke(Path(box), with: .color(target.color.opacity(0.55)), lineWidth: 0.8)
            let label = Text(target.label)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(target.color.opacity(0.65))
            context.draw(label, at: CGPoint(x: center.x + 5, y: center.y), anchor: .leading)
        }
    }

    private func vectorscopePoint(_ point: VectorPoint, in plot: CGRect) -> CGPoint {
        // U on x, V on y. Render-coordinate y grows downward, so we invert V
        // for a screen-correct read (positive V points red -> upper).
        let radius = min(plot.width, plot.height) / 2
        return CGPoint(x: plot.midX + CGFloat(point.u) * radius,
                       y: plot.midY - CGFloat(point.v) * radius)
    }

    private func placeholder(into context: GraphicsContext, size: CGSize, label: String) {
        let text = Text(label).font(.caption2).foregroundStyle(.white.opacity(0.4))
        context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
    }
}
