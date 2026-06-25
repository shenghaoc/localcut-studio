import SwiftUI

/// Shared header treatment for the editor's primary panes.
struct EditorPanelHeader<Trailing: View>: View {
    let title: String
    let systemImage: String?
    private let trailing: Trailing

    init(_ title: String, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension EditorPanelHeader where Trailing == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = EmptyView()
    }
}
