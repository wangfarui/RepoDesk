import Testing
@testable import RepoDesk

struct AppSectionTests {
    @Test func allSectionsHaveStableDistinctIdentifiers() {
        let sections = AppSection.allCases

        #expect(Set(sections.map(\.id)).count == sections.count)
        #expect(sections.map(\.rawValue) == ["Overview", "Changes", "Files", "History", "Tasks"])
    }
}
