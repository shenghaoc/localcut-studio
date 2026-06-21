import SwiftUI
import AVKit

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

/// The preview pane: video canvas plus a transport bar with the playhead time.
struct PreviewView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
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

            Text(TimeFormatting.timecode(model.currentTime))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("/")
                .foregroundStyle(.tertiary)
            Text(TimeFormatting.timecode(model.totalDuration))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(Int(model.project.renderSize.width))×\(Int(model.project.renderSize.height)) · \(Int(model.project.frameRate)) fps")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
    }
}

/// Shared seconds → timecode formatting.
enum TimeFormatting {
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.00" }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let hundredths = Int((seconds - floor(seconds)) * 100)
        return String(format: "%d:%02d.%02d", minutes, secs, hundredths)
    }
}
