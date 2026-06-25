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

private struct TransportTimeView: View {
    var model: EditorModel

    var body: some View {
        let current = TimeFormatting.timecode(model.currentTime)
        let duration = TimeFormatting.timecode(model.totalDuration)

        HStack(spacing: 4) {
            Text(current)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("/")
                .foregroundStyle(.tertiary)
            Text(duration)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Playhead \(current) of \(duration)"))
    }
}

/// The preview pane: video canvas plus a transport bar with the playhead time.
struct PreviewView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    if model.player.currentItem != nil {
                        PreviewPlayerView(player: model.player)
                    } else {
                        ContentUnavailableView(
                            "No Preview",
                            systemImage: "film.stack",
                            description: Text("Add a clip to the timeline to see it here."))
                        .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .layoutPriority(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Preview")
                .accessibilityValue(previewAccessibilityValue)

                if model.showScopes {
                    ScopesView()
                        .frame(minWidth: 200, idealWidth: 240)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.default, value: model.showScopes)

            transportBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button {
                model.seek(toSeconds: 0)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Go to start")
            .accessibilityLabel("Go to start")

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / Pause")
            .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))

            TransportTimeView(model: model)

            Spacer()

            Text("\(Int(model.project.renderSize.width))×\(Int(model.project.renderSize.height)) · \(Int(model.project.frameRate)) fps")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Project render format")
        }
        .buttonStyle(.borderless)
    }

    private var previewAccessibilityValue: String {
        if model.player.currentItem == nil {
            return String(localized: "No preview. Add a clip to the timeline to see it here.")
        }
        return String(localized: "Showing the current timeline frame.")
    }
}
