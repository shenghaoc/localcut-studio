import SwiftUI
import AVKit
import LocalCutCore

/// Wraps AVKit's native `AVPlayerView` so the composition renders with hardware
/// acceleration and standard playback chrome.
struct PreviewPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none           // we drive transport from the editor
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

/// Floating playback controls. Value-based (no `EditorModel`) so it previews in
/// isolation and stays a pure control surface. As interactive controls floating
/// over video, this is the canonical Liquid Glass case — the glass capsule
/// supplies its own material, so nothing here hard-codes a colour or background.
private struct TransportControls: View {
    let isPlaying: Bool
    let current: String
    let duration: String
    let skipToStart: () -> Void
    let togglePlayPause: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: skipToStart) {
                Image(systemName: "backward.end.fill")
            }
            .help("Go to start")
            .accessibilityLabel("Go to start")

            Button(action: togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / Pause")
            .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))

            HStack(spacing: 4) {
                Text(current).monospacedDigit().foregroundStyle(.secondary)
                Text("/").foregroundStyle(.tertiary)
                Text(duration).monospacedDigit().foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Playhead \(current) of \(duration)"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive())
    }
}

/// The preview pane: video canvas plus a transport bar with the playhead time.
struct PreviewView: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            videoCanvas
                // Collapse the non-interactive canvas to a single labelled element
                // *before* the overlays are added, so the transport controls and
                // format badge stay separate accessible siblings rather than being
                // swallowed (or read twice) inside the preview container.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Preview")
                .accessibilityValue(previewAccessibilityValue)
                .overlay(alignment: .bottom) {
                    TransportControls(
                        isPlaying: model.isPlaying,
                        current: TimeFormatting.timecode(model.currentTime),
                        duration: TimeFormatting.timecode(model.totalDuration),
                        skipToStart: { model.seek(toSeconds: 0) },
                        togglePlayPause: { model.togglePlayPause() })
                    .padding(.bottom, 16)
                }
                .overlay(alignment: .topTrailing) {
                    formatBadge.padding(12)
                }
                .layoutPriority(1)

            if model.showScopes {
                ScopesView()
                    .frame(minWidth: 200, idealWidth: 240)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.default, value: model.showScopes)
    }

    private var videoCanvas: some View {
        ZStack {
            Color.black
            if model.player.currentItem != nil {
                PreviewPlayerView(player: model.player)
            } else {
                ContentUnavailableView(
                    "No Preview",
                    systemImage: "film.stack",
                    description: Text("Add a clip to the timeline to see it here."))
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Informational render-format readout. A non-interactive label belongs to
    /// the content layer, so it uses a standard material capsule rather than
    /// Liquid Glass (HIG: glass is reserved for the interactive/functional layer).
    private var formatBadge: some View {
        Text("\(Int(model.project.renderSize.width))×\(Int(model.project.renderSize.height)) · \(Int(model.project.frameRate)) fps")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: .capsule)
            .help("Project render format")
            // VoiceOver would otherwise read the raw "1920×1080 · 30 fps" glyphs;
            // spell out the dimensions and frame rate instead.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Render format"))
            .accessibilityValue(String(localized: "\(Int(model.project.renderSize.width)) by \(Int(model.project.renderSize.height)), \(Int(model.project.frameRate)) frames per second"))
    }

    private var previewAccessibilityValue: String {
        if model.player.currentItem == nil {
            return String(localized: "No preview. Add a clip to the timeline to see it here.")
        }
        return String(localized: "Showing the current timeline frame.")
    }
}
// Renders the floating transport over a media-like gradient so the Liquid Glass
// capsule can be inspected in isolation (the gradient is preview scaffolding to
// stand in for video — it is not shipped UI).
#Preview("Transport over media") {
    ZStack {
        LinearGradient(colors: [.indigo, .blue, .black],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        VStack {
            Spacer()
            TransportControls(
                isPlaying: false,
                current: "00:00:02:10",
                duration: "00:01:23:00",
                skipToStart: {},
                togglePlayPause: {})
            .padding(.bottom, 16)
        }
    }
    .frame(width: 560, height: 320)
}

