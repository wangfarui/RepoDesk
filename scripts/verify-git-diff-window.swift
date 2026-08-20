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
        let controller = GitDiffComparisonWindowController()
        let title = "RepoDesk Diff Window Verification"
        controller.present(title: title) {
            Color.clear.frame(width: 1_200, height: 760)
        }
        guard let window = NSApp.windows.first(where: { $0.title == title }) else {
            throw GitDiffWindowVerificationError(message: "Comparison window was not presented.")
        }
        try require(window.styleMask.contains(.titled), "Comparison window is not movable.")
        try require(window.styleMask.contains(.resizable), "Comparison window is not resizable.")
        try require(window.isMovableByWindowBackground, "Custom header cannot drag the window.")
        try require(window.minSize.width == 1_050, "Unexpected minimum comparison width.")
        try require(window.minSize.height == 680, "Unexpected minimum comparison height.")
        window.cancelOperation(nil)
        try require(!window.isVisible, "Escape did not close the comparison window.")
        print("Git diff window verification passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GitDiffWindowVerificationError(message: message) }
    }
}
