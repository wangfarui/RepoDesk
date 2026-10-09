import AppKit
import SwiftUI

struct GitBlameAnnotationCell: View {
    let blame: GitBlameLine?
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(blame?.authoredAt.map(Self.dateFormatter.string(from:)) ?? "")
                .frame(width: 58, alignment: .leading)
            Text(blame?.author ?? "")
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            Text(blame?.isUncommitted != false ? "" : String(blame?.commitHash.prefix(8) ?? ""))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
        }
        .font(.caption2.monospaced())
        .foregroundStyle(blame?.isUncommitted != false ? .secondary : .primary)
        .padding(.horizontal, 7)
        .frame(width: 226, alignment: .leading)
        .frame(height: height)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy/MM/dd"
        return formatter
    }()
}
