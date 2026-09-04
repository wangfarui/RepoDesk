import AppKit
import SwiftUI

private struct GitDiffWindowVerificationError: Error {
    let message: String
}

@main
@MainActor
enum GitDiffWindowVerification {
    static func main() throws {
        _ = NSApplication.shared
        let controller = GitDiffWindowController(frameAutosaveName: "RepoDesk.GitDiffComparison")
        let title = "RepoDesk Diff Window Verification"
        controller.present(title: title) {
            Color.clear.frame(width: 1_200, height: 760)
        }
        guard let window = NSApp.windows.first(where: { $0.title == title }) else {
            throw GitDiffWindowVerificationError(message: "Comparison window was not presented.")
        }
        try require(window.styleMask.contains(.titled), "Comparison window is not movable.")
        try require(window.styleMask.contains(.resizable), "Comparison window is not resizable.")
        try require(window.sheetParent == nil, "Comparison window must be a top-level window.")
        try require(window.isMovableByWindowBackground, "Custom header cannot drag the window.")
        try require(window.minSize.width == 1_050, "Unexpected minimum comparison width.")
        try require(window.minSize.height == 680, "Unexpected minimum comparison height.")
        window.cancelOperation(nil)
        try require(!window.isVisible, "Escape did not close the comparison window.")

        let pushController = GitDiffWindowController(frameAutosaveName: "RepoDesk.GitPushDiff")
        let firstTitle = "Push Diff - First.swift"
        pushController.present(title: firstTitle) {
            Color.red.frame(width: 1_200, height: 760)
        }
        guard let pushWindow = NSApp.windows.first(where: { $0.title == firstTitle }) else {
            throw GitDiffWindowVerificationError(message: "Push Diff window was not presented.")
        }
        let firstContentController = pushWindow.contentViewController
        let pushWindowID = ObjectIdentifier(pushWindow)
        let secondTitle = "Push Diff - Second.swift"
        pushController.present(title: secondTitle) {
            Color.blue.frame(width: 1_200, height: 760)
        }
        guard let reusedWindow = NSApp.windows.first(where: { $0.title == secondTitle }) else {
            throw GitDiffWindowVerificationError(message: "Push Diff window title was not updated.")
        }
        try require(ObjectIdentifier(reusedWindow) == pushWindowID, "Push Diff opened more than one window.")
        try require(reusedWindow.contentViewController !== firstContentController, "Push Diff content was not replaced.")
        try require(reusedWindow.sheetParent == nil, "Push Diff must be a top-level window.")
        pushController.close()
        print("Git diff window verification passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GitDiffWindowVerificationError(message: message) }
    }
}
