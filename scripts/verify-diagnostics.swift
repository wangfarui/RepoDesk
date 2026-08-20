import Foundation

enum DiagnosticVerificationError: LocalizedError {
    case missingEntry

    var errorDescription: String? {
        "Diagnostic log did not contain the recorded entry."
    }
}

@main
struct DiagnosticVerification {
    static func main() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskDiagnostics-\(UUID().uuidString)", isDirectory: true)
        let logURL = rootURL.appendingPathComponent("RepoDesk.log", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let logger = AppDiagnosticLogger(logURL: logURL)
        let marker = "verification-\(UUID().uuidString)"

        await logger.record(marker)

        let content = try String(contentsOf: logURL, encoding: .utf8)
        guard content.contains(marker) else {
            throw DiagnosticVerificationError.missingEntry
        }
        print("Diagnostic logging verification passed")
    }
}
