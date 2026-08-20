import SwiftUI

struct SearchableFilterPopover<Content: View>: View {
    @Binding var query: String
    let placeholder: String
    @ViewBuilder let content: Content

    init(
        query: Binding<String>,
        placeholder: String,
        @ViewBuilder content: () -> Content
    ) {
        _query = query
        self.placeholder = placeholder
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) { content }
            }
        }
        .padding(10)
        .frame(width: 300, height: 340)
    }
}
