import SwiftUI

struct MarkdownDocumentView: View {
    let text: String
    let fileName: String

    private var blocks: [MarkdownPreviewBlock] {
        MarkdownPreviewParser.parse(text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.secondary)
                Text(fileName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownPreviewBlock

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let level, let text):
            MarkdownInlineText(source: text)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .textSelection(.enabled)
                .padding(.top, level == 1 ? 4 : 12)
                .padding(.bottom, level <= 2 ? 10 : 6)
        case .paragraph(let text):
            MarkdownInlineText(source: text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.bottom, 12)
        case .listItem(let item):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                listMarker(item.marker)
                    .frame(width: 24, alignment: .trailing)
                MarkdownInlineText(source: item.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(item.depth) * 20)
            .padding(.bottom, 5)
        case .blockQuote(let text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                MarkdownInlineText(source: text)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.07))
            .padding(.bottom, 12)
        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                }
                ScrollView(.horizontal) {
                    Text(verbatim: code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.09))
            .clipShape(.rect(cornerRadius: 5))
            .padding(.bottom, 14)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 14)
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
                .padding(.bottom, 16)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28
        case 2: 23
        case 3: 19
        case 4: 17
        default: 15
        }
    }

    @ViewBuilder
    private func listMarker(_ marker: MarkdownPreviewListItem.Marker) -> some View {
        switch marker {
        case .unordered:
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
        case .ordered(let number):
            Text("\(number).")
                .font(.body.monospacedDigit())
        case .task(let isChecked):
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(1, max(headers.count, rows.map(\.count).max() ?? 0))
    }

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, isHeader: false)
                }
            }
        }
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { index in
                MarkdownInlineText(source: index < cells.count ? cells[index] : "")
                    .font(isHeader ? .body.weight(.semibold) : .body)
                    .textSelection(.enabled)
                    .frame(width: 180, alignment: .leading)
                    .padding(8)
                    .background(isHeader ? Color.secondary.opacity(0.11) : Color.clear)
                    .overlay {
                        Rectangle()
                            .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                    }
            }
        }
    }
}

private struct MarkdownInlineText: View {
    let source: String

    @ViewBuilder
    var body: some View {
        if let attributed = try? AttributedString(markdown: source) {
            Text(attributed)
        } else {
            Text(source)
        }
    }
}
