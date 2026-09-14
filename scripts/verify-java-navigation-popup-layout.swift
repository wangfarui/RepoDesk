import AppKit
@testable import RepoDesk

@main
struct VerifyJavaNavigationPopupLayout {
    static func main() throws {
        let popupSize = CGSize(width: 760, height: 250)
        let availableSize = CGSize(width: 1_263, height: 760)
        let anchor = JavaNavigationPopupAnchor(x: 1_000, y: 360)
        let origin = JavaNavigationPopupLayout.origin(
            anchor: anchor,
            popupSize: popupSize,
            availableSize: availableSize
        )
        try require(
            origin.x + popupSize.width <= CGFloat(anchor.x) - JavaNavigationPopupLayout.anchorGap,
            "Popup did not move fully to the left when the right side was too narrow: \(origin.x)"
        )

        let fileNames = [
            "ProcessingNotifyApiTest.java",
            "ProcessingNotifyApiImplUnitTest.java"
        ]
        let requiredWidth = JavaNavigationPopupLayout.requiredFileColumnWidth(fileNames: fileNames)
        let actualWidth = JavaNavigationPopupLayout.fileColumnWidth(
            fileNames: fileNames,
            popupWidth: popupSize.width
        )
        try require(
            actualWidth >= requiredWidth,
            "File-name column is too narrow: actual \(actualWidth), required \(requiredWidth)"
        )
        try require(
            JavaNavigationPopupLayout.matchesFileName(
                "ProcessingNotifyOrderManagerTest.java",
                query: "pnomt"
            ),
            "Fuzzy file-name matching did not match an in-order abbreviation"
        )
        try require(
            !JavaNavigationPopupLayout.matchesFileName(
                "ProcessingNotifyOrderManagerTest.java",
                query: "xyz"
            ),
            "Fuzzy file-name matching returned a false positive"
        )
        try require(
            JavaNavigationPopupLayout.matchesFileName(
                "ProcessingNotifyOrderManager.java",
                query: "manager"
            ),
            "Fuzzy file-name matching did not match a class-name substring"
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }

    private enum VerificationError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case .failed(let message): message
            }
        }
    }
}
