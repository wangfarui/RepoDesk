import Foundation
import SwiftUI

@MainActor
enum HistoryCommitPresentation {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    static func dateLabel(_ date: Date, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> String {
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "今天 \(formatter.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "HH:mm"
            return "昨天 \(formatter.string(from: date))"
        }
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

struct HistoryContainingBranchesView: View {
    let branches: [String]
    @State private var showsAll = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("In \(branches.count) branches: \(preview)")
                .lineLimit(1)
                .truncationMode(.tail)
            if !branches.isEmpty {
                Button("显示全部") { showsAll = true }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .popover(isPresented: $showsAll, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("包含此提交的分支（\(branches.count)）")
                                .fontWeight(.semibold)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(branches.enumerated()), id: \.offset) { _, branch in
                                        Text(branch)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .textSelection(.enabled)
                                .padding(.trailing, 8)
                            }
                            .frame(maxHeight: 260)
                        }
                        .padding(12)
                        .frame(width: 400)
                    }
            }
        }
        .font(.callout)
        .help("包含此提交的本地分支和远程跟踪分支")
    }

    private var preview: String {
        branches.prefix(5).joined(separator: ", ") + (branches.count > 5 ? "…" : "")
    }
}
