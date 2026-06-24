import SwiftUI
import AppKit
import LocalCutCore

/// A translucent overlay that surfaces the `DiagnosticsAgent`'s probes. Anchored
/// top-trailing on the editor view; togglable from View ▸ Show Diagnostics.
struct DiagnosticsView: View {
    // Read-only — the view never creates `$agent.foo` bindings, so `let` is
    // enough. `@Observable` tracking happens on plain property reads inside
    // `body`; `@Bindable` would expose write access to every property of the
    // agent, which would be semantic overreach here.
    let agent: DiagnosticsAgent

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
            Divider()
            capabilitiesSection
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

    // MARK: - Capabilities

    /// Surfaces the capability resolver's verdicts — computed once at launch but
    /// previously read by nothing. The Diagnostics panel is the agreed home
    /// (feature-capability-tiers R3.3): the per-feature reason rides in `.help`
    /// so a creator can tell *why* a feature is degraded.
    @ViewBuilder
    private var capabilitiesSection: some View {
        let caps = Capabilities.current
        VStack(alignment: .leading, spacing: 4) {
            Text("Capabilities")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            capabilityRow("Effect chain", caps.tier(for: .metalEffectChain))
            capabilityRow("Frame interp.", caps.tier(for: .frameInterpolation))
            capabilityRow("Capture ×2", caps.tier(for: .simultaneousCaptureStreams(count: 2)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hardware capability tiers")
    }

    private func capabilityRow(_ label: String, _ verdict: CapabilityVerdict) -> some View {
        LabeledContent {
            Text(tierLabel(verdict.tier))
                .foregroundStyle(tierTint(verdict.tier))
        } label: {
            Text(label).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .help(verdict.reason)
    }

    private func tierLabel(_ tier: CapabilityTier) -> String {
        switch tier {
        case .baseline: "Baseline"
        case .accelerated: "Accelerated"
        case .pro: "Pro"
        }
    }

    private func tierTint(_ tier: CapabilityTier) -> Color {
        switch tier {
        case .baseline: .gray
        case .accelerated: .yellow
        case .pro: .green
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        // A single sample renders as nothing through `Path.addLine` (only
        // `move(to:)` runs, then `stroke` draws nothing), which would look
        // identical to a stuck blank area instead of the em-dash empty state.
        // Treat <2 samples the same as zero samples.
        if agent.sparkline.count < 2 {
            // Empty state shouldn't read as a stuck zero — an em dash is clearer.
            HStack {
                Spacer()
                Text("—")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        } else {
            let samples = agent.sparkline
            GeometryReader { proxy in
                Path { path in
                    guard let maxSample = samples.max(), maxSample > 0 else { return }
                    // Floor the y-axis at the 60 fps budget (~16.6 ms) so a
                    // sub-millisecond render fluctuation doesn't stretch into a
                    // wildly misleading peak. A real spike past the budget
                    // pushes the scale up as before.
                    let maxValue = max(16.6, maxSample)
                    let stepX = proxy.size.width / CGFloat(samples.count - 1)
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
