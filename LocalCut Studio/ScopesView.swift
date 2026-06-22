import SwiftUI

/// One of the scope panels the user can switch between.
enum ScopeKind: String, CaseIterable, Identifiable {
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
/// latest sample published by `ScopeSampler.shared`. On appear / disappear the
/// view flips the sampler's `enabled` flag so a hidden panel pays no per-frame
/// cost in the compositor's hot path.
struct ScopesView: View {
    let sampler: ScopeSampler
    @State private var kind: ScopeKind = .waveform

    init(sampler: ScopeSampler = .shared) {
        self.sampler = sampler
    }

    var body: some View {
        // Touch the observed properties here so SwiftUI's @Observable tracking
        // registers them at body evaluation time (Canvas closures execute later).
        let sample = sampler.latest
        let _ = sampler.revision

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
                    drawWaveform(into: context, size: size, sample: sample)
                case .vectorscope:
                    drawVectorscope(into: context, size: size, sample: sample)
                }
            }
            .background(Color.black)
            .cornerRadius(4)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .accessibilityLabel(kind == .waveform ? "Waveform scope" : "Vectorscope")
        }
        .frame(minWidth: 200, idealWidth: 240, minHeight: 160, idealHeight: 220)
        .background(.regularMaterial)
        .onAppear { sampler.setEnabled(true) }
        .onDisappear { sampler.setEnabled(false) }
    }

    // MARK: - Waveform

    private func drawWaveform(into context: GraphicsContext, size: CGSize, sample: ScopeSample?) {
        // Frame outline.
        let frameRect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        context.stroke(Path(frameRect), with: .color(.white.opacity(0.15)), lineWidth: 0.5)

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

    // MARK: - Vectorscope

    private func drawVectorscope(into context: GraphicsContext, size: CGSize, sample: ScopeSample?) {
        let frameRect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let plotSide = min(frameRect.width, frameRect.height)
        let plot = CGRect(x: frameRect.midX - plotSide / 2,
                          y: frameRect.midY - plotSide / 2,
                          width: plotSide, height: plotSide)

        // Outer chroma circle + crosshairs as a reference grid.
        context.stroke(Path(ellipseIn: plot), with: .color(.white.opacity(0.2)), lineWidth: 0.5)
        var crosshair = Path()
        crosshair.move(to: CGPoint(x: plot.midX, y: plot.minY))
        crosshair.addLine(to: CGPoint(x: plot.midX, y: plot.maxY))
        crosshair.move(to: CGPoint(x: plot.minX, y: plot.midY))
        crosshair.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        context.stroke(crosshair, with: .color(.white.opacity(0.1)), lineWidth: 0.5)

        guard let sample, !sample.vectorscope.isEmpty else {
            placeholder(into: context, size: size, label: "No frames yet")
            return
        }

        let radius = plotSide / 2
        for point in sample.vectorscope {
            // U on x, V on y. Render-coordinate y grows downward, so we invert
            // V for a screen-correct read (positive V points red → upper).
            let x = plot.midX + CGFloat(point.u) * radius
            let y = plot.midY - CGFloat(point.v) * radius
            let dot = CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)
            context.fill(Path(ellipseIn: dot), with: .color(.green.opacity(0.7)))
        }
    }

    private func placeholder(into context: GraphicsContext, size: CGSize, label: String) {
        let text = Text(label).font(.caption2).foregroundStyle(.white.opacity(0.4))
        context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
    }
}
