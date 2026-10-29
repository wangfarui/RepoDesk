import AppKit
import SwiftUI

struct GitBlameAnnotationCell: View {
    static let width = GitBlamePalette.annotationWidth

    let blame: GitBlameLine?
    let height: CGFloat
    let colorScale: GitBlameColorScale

    var body: some View {
        HStack(spacing: 6) {
            Text(blame?.authoredAt.map(GitBlamePalette.dateFormatter.string(from:)) ?? "")
                .frame(width: 74, alignment: .leading)
            Text(blame?.author ?? "")
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
        }
        .font(.caption2.monospaced())
        .foregroundStyle(Color(nsColor: blame?.isUncommitted != false
            ? .secondaryLabelColor : GitBlamePalette.foreground(for: colorLevel)))
        .padding(.horizontal, 7)
        .frame(width: Self.width, alignment: .leading)
        .frame(height: height)
        .background(Color(nsColor: GitBlamePalette.background(for: colorLevel)))
        .help(blame.map {
            GitBlamePalette.detailText(hash: $0.commitHash, author: $0.author, email: $0.authorEmail,
                                      date: $0.authoredAt, message: $0.message, isUncommitted: $0.isUncommitted)
        } ?? "没有提交信息")
    }

    private var colorLevel: Int? {
        blame?.isUncommitted == false ? colorScale.level(for: blame?.authoredAt) : nil
    }

}
