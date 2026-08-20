import SwiftUI

struct StreamingOutputView: View {
    let text: String
    let emptyMessage: String
    let emptyMessageColor: Color
    let enablesTailFollowing: Bool
    let contentIdentity: String
    @Binding var followsTail: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NativeCodeEditor(
                text: .constant(text),
                isEditable: false,
                followsTail: enablesTailFollowing ? $followsTail : nil,
                contentIdentity: contentIdentity
            )

            if text.isEmpty {
                Text(emptyMessage)
                    .font(.body.monospaced())
                    .foregroundStyle(emptyMessageColor)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            if enablesTailFollowing, !followsTail, !text.isEmpty {
                Button("跳转到最新输出", systemImage: "arrow.down.to.line") {
                    followsTail = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("跳转到最新输出并继续自动跟随")
                .padding(12)
            }
        }
    }
}
