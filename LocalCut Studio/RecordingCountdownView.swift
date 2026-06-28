import SwiftUI

/// Full-screen overlay that displays a countdown before recording starts.
/// Shown as a sheet or overlay from the recorder setup or main content view.
struct RecordingCountdownView: View {
    @Bindable var model: EditorModel
    let totalSeconds: Int

    @State private var remaining: Int
    @State private var scale: CGFloat = 1.0

    init(model: EditorModel, totalSeconds: Int) {
        self.model = model
        self.totalSeconds = totalSeconds
        _remaining = State(initialValue: totalSeconds)
    }

    var body: some View {
        ZStack {
            // Semi-transparent backdrop.
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text(remaining > 0 ? "\(remaining)" : "Recording")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(remaining > 0 ? .white : .red)
                    .scaleEffect(scale)
                    .animation(.easeInOut(duration: 0.3), value: scale)
                    .accessibilityLabel(remaining > 0
                        ? "Starting in \(remaining) seconds"
                        : "Recording started")

                if remaining > 0 {
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
            remaining = totalSeconds
            startCountdown()
        }
    }

    private func startCountdown() {
        Task { @MainActor in
            for second in (1...totalSeconds).reversed() {
                remaining = second
                // Pulse animation.
                withAnimation(.easeInOut(duration: 0.15)) { scale = 1.2 }
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.easeInOut(duration: 0.15)) { scale = 1.0 }
                try? await Task.sleep(for: .milliseconds(850))
            }
            // "Recording" flash.
            remaining = 0
            withAnimation(.easeInOut(duration: 0.2)) { scale = 1.1 }
            try? await Task.sleep(for: .milliseconds(600))
        }
    }
}
