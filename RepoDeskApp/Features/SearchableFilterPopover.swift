import SwiftUI

struct SearchableFilterPopover<Content: View>: View {
    @Binding var query: String
    let placeholder: String
    let autoFocus: Bool
    let width: CGFloat
    @ViewBuilder let content: Content
    @FocusState private var isQueryFocused: Bool

    init(
        query: Binding<String>,
        placeholder: String,
        autoFocus: Bool = false,
        width: CGFloat = 300,
        @ViewBuilder content: () -> Content
    ) {
        _query = query
        self.placeholder = placeholder
        self.autoFocus = autoFocus
        self.width = width
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isQueryFocused)
                .accessibilityIdentifier("RepoDesk.SearchableFilterPopover.Input")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) { content }
            }
        }
        .padding(10)
        .frame(width: width, height: 340)
        .onAppear {
            if autoFocus { isQueryFocused = true }
        }
    }
}
