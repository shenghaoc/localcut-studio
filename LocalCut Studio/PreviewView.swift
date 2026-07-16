import SwiftUI
import AVKit
import LocalCutCore
import LocalCutDomain

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
    let hasContent: Bool
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
            // Spacebar play/pause is handled by the window-level EditorKeyHandler
            // (a local NSEvent monitor that defers to text-input first responders),
            // not a `.keyboardShortcut` here: a key-equivalent — on a menu Command
            // *or* a view button — fires before a focused text field gets the
            // event, so it would swallow spaces typed into the marker-rename
            // popover / caption fields.
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
        // No content ⇒ the transport is a live-looking no-op; disable it so the
        // controls give honest feedback.
        .disabled(!hasContent)
    }
}

/// The preview pane: video canvas plus a transport bar with the playhead time.
struct PreviewView: View {
    @Bindable var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            videoCanvas
                // Collapse the non-interactive canvas to a single labelled element
                // *before* the overlays are added, so the empty-state action,
                // transport controls, and badges stay separate accessible siblings
                // rather than being swallowed (or read twice) inside the preview
                // container.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Preview")
                .accessibilityValue(previewAccessibilityValue)
                .overlay {
                    emptyPreviewState
                }
                .overlay(alignment: .bottom) {
                    TransportOverlay(model: model)
                        .padding(.bottom, 16)
                }
                .overlay(alignment: .topTrailing) {
                    formatBadge.padding(12)
                }
                .overlay(alignment: .topLeading) {
                    safeZoneBadge.padding(12)
                }
                .layoutPriority(1)

            if model.showScopes {
                ScopesView()
                    .frame(minWidth: 200, idealWidth: 240)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            }
        }
        .animation(reduceMotion ? nil : .default, value: model.showScopes)
    }

    private var videoCanvas: some View {
        ZStack {
            Color.black
            if model.hasPreviewItem {
                PreviewPlayerView(player: model.player)
            }
            if model.showSafeZones,
               let profile = SafeZoneLibrary.validProfile(
                id: model.selectedSafeZoneProfileID,
                for: model.project.aspect,
                renderSize: model.project.renderSize) {
                SafeZoneOverlayView(
                    profile: profile,
                    renderSize: model.project.renderSize)
            }
        }
    }

    @ViewBuilder
    private var emptyPreviewState: some View {
        if !model.hasPreviewItem {
            ContentUnavailableView {
                Label("No Preview", systemImage: "film.stack")
                    .foregroundStyle(.secondary)
            } description: {
                Text("Import media, then drag a clip to the timeline.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
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
            .accessibilityLabel(Text("Render format"))
            .accessibilityValue(Text("\(Int(model.project.renderSize.width)) by \(Int(model.project.renderSize.height)), \(Int(model.project.frameRate)) frames per second"))
    }

    @ViewBuilder
    private var safeZoneBadge: some View {
        if model.showSafeZones,
           let profile = SafeZoneLibrary.validProfile(
            id: model.selectedSafeZoneProfileID,
            for: model.project.aspect,
            renderSize: model.project.renderSize) {
            Text(profile.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: .capsule)
                .help("Safe-zone profile")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Safe-zone profile"))
                .accessibilityValue(Text(profile.displayName))
        }
    }

    /// Extracted view to isolate `@Observable` high-frequency updates (like `model.currentTime`)
    /// from the main `PreviewView.body`, preventing unnecessary re-renders of the large
    /// canvas component during playback.
    @MainActor
    private struct TransportOverlay: View {
        let model: EditorModel

        var body: some View {
            TransportControls(
                isPlaying: model.isPlaying,
                current: TimeFormatting.timecode(model.currentTime),
                duration: TimeFormatting.timecode(model.totalDuration),
                hasContent: model.hasPreviewItem,
                skipToStart: { model.seek(toSeconds: 0) },
                togglePlayPause: { model.togglePlayPause() })
        }
    }

    private var previewAccessibilityValue: String {
        if !model.hasPreviewItem {
            return String(localized: "No preview. Import media, then drag a clip to the timeline.")
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
                hasContent: true,
                skipToStart: {},
                togglePlayPause: {})
            .padding(.bottom, 16)
        }
    }
    .frame(width: 560, height: 320)
}
