import SwiftUI
import AppKit

/// A translucent overlay that surfaces the `DiagnosticsAgent`'s probes. Anchored
/// top-trailing on the editor view; togglable from View ▸ Show Diagnostics.
struct DiagnosticsView: View {
    @Bindable var agent: DiagnosticsAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "speedometer")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Diagnostics")
                    .font(.headline)
                Spacer()
            }
            Divider()
            row("CPU", value: percent(agent.cpuUtilisation))
            row("GPU (est.)", value: percent(agent.gpuUtilisation))
                .help("Estimated from the compositor's share of frame budget — macOS 26 has no public counter API without entitlements.")
            row("Decoders", value: "\(agent.decoderCount)")
            row("Last render", value: millis(agent.lastFrameTime))
            row("P95 render", value: millis(agent.p95RenderTime))
            row("Drops / s", value: "\(agent.frameDropsLastTick)")
            Divider()
            sparkline
                .frame(height: 36)
                .accessibilityLabel("Render-time sparkline, milliseconds")
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1))
        .shadow(radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Diagnostics panel")
    }

    private func row(_ label: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        } label: {
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func millis(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return String(format: "%.1f ms", seconds * 1000)
    }

    @ViewBuilder
    private var sparkline: some View {
        if agent.sparkline.isEmpty {
            // Empty state shouldn't read as a stuck zero — an em dash is clearer.
            HStack {
                Spacer()
                Text("—")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        } else {
            GeometryReader { proxy in
                Path { path in
                    let samples = agent.sparkline
                    guard let maxSample = samples.max(), maxSample > 0 else { return }
                    // Floor the y-axis at the 60 fps budget (~16.6 ms) so a
                    // sub-millisecond render fluctuation doesn't stretch into a
                    // wildly misleading peak. A real spike past the budget
                    // pushes the scale up as before.
                    let maxValue = max(16.6, maxSample)
                    let stepX = samples.count > 1 ? proxy.size.width / CGFloat(samples.count - 1) : 0
                    let scaleY = proxy.size.height / CGFloat(maxValue)
                    for (i, value) in samples.enumerated() {
                        let point = CGPoint(
                            x: CGFloat(i) * stepX,
                            y: proxy.size.height - CGFloat(value) * scaleY)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}

/// Wraps `NSVisualEffectView` so a SwiftUI panel can pick up the system's
/// translucent HUD background without leaking AppKit through the rest of the
/// view code.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
