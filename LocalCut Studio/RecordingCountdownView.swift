import SwiftUI

/// Full-screen overlay that displays a countdown before recording starts.
/// Shown as a sheet or overlay from the recorder setup or main content view.
struct RecordingCountdownView: View {
    @Bindable var model: EditorModel

    @State private var scale: CGFloat = 1.0

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        ZStack {
            // Semi-transparent backdrop.
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text(model.countdownRemaining > 0 ? "\(model.countdownRemaining)" : "Recording")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(model.countdownRemaining > 0 ? .white : .red)
                    .scaleEffect(scale)
                    .animation(.easeInOut(duration: 0.3), value: scale)
                    .accessibilityLabel(model.countdownRemaining > 0
                        ? "Starting in \(model.countdownRemaining) seconds"
                        : "Recording started")

                if model.countdownRemaining > 0 {
                    Button("Cancel") {
                        model.cancelCountdown()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Cancel countdown")
                }
            }
        }
        .onAppear {
            pulse()
        }
        .onChange(of: model.countdownRemaining) { _, newValue in
            guard newValue > 0 else { return }
            pulse()
        }
    }

    private func pulse() {
        withAnimation(.easeInOut(duration: 0.15)) { scale = 1.2 }
        withAnimation(.easeInOut(duration: 0.2).delay(0.15)) { scale = 1.0 }
    }
}
