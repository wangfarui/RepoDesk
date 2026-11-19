import Foundation
@testable import RepoDesk

enum RepositoryContextVerificationError: Error, CustomStringConvertible {
    case mismatch(String)

    var description: String {
        switch self {
        case .mismatch(let message): message
        }
    }
}

@main
struct RepositoryContextVerification {
    @MainActor
    static func main() throws {
        let member = RegisteredRepository(
            displayName: "example.services.member.service",
            relativePath: "member",
            isPinned: false
        )
        let center = RegisteredRepository(
            displayName: "example.services.sample-platform.service",
            relativePath: "center",
            isPinned: false
        )
        let memberSelection = GitChangeSelection(path: "Member.java", kind: .changes)
        let centerSelection = GitChangeSelection(path: "Center.java", kind: .changes)
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/repodesk-context-verification"),
            repositories: [center, member],
            selectedRepositoryID: member.id,
            restoresWorkspaceOnLaunch: false
        )

        state.selectedSection = .changes
        state.rememberedChangeSelections[member.id] = memberSelection
        state.selectedChangeRepositoryID = center.id
        state.selectedChange = centerSelection
        state.currentDiff = GitFileDiff(
            path: centerSelection.path,
            originalPath: nil,
            oldLabel: "a/Center.java",
            newLabel: "b/Center.java",
            oldLines: ["old"],
            newLines: ["new"],
            hunks: [],
            isBinary: false
        )

        state.selectRepositoryContext(member.id)

        try require(state.navigationContext == .repository(member.id), "repository context did not switch to member")
        try require(state.selectedRepositoryID == member.id, "selected repository is not member")
        try require(state.changesRepositoryScopeID == member.id, "Changes scope is not member")
        try require(state.selectedChangeRepositoryID == member.id, "selected change still belongs to center")
        try require(state.selectedChange == memberSelection, "Changes file selection was not restored for member")
        try require(state.currentDiff == nil, "Changes Diff still shows center content")

        print("Repository context verification passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw RepositoryContextVerificationError.mismatch(message)
        }
    }
}
