import SwiftUI

/// Shared header treatment for the editor's primary panes. Call sites own the
/// surrounding separators (this view draws no `Divider`) so headers can compose
/// with adjacent pane controls. `verticalPadding` defaults to 8 (Inspector,
/// Media); the Timeline passes 6 to keep its gutter/ruler alignment exact.
struct EditorPanelHeader<Trailing: View>: View {
    let title: String
    let verticalPadding: CGFloat
    private let trailing: Trailing

    init(_ title: String, verticalPadding: CGFloat = 8, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.verticalPadding = verticalPadding
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
    }
}

extension EditorPanelHeader where Trailing == EmptyView {
    init(_ title: String, verticalPadding: CGFloat = 8) {
        self.title = title
        self.verticalPadding = verticalPadding
        self.trailing = EmptyView()
    }
}
