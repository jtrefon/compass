import Foundation

public protocol CrashReporting: Sendable {
    func setProjectRoot(_ root: URL) async

    func capture(
        _ error: Error,
        context: CrashReportContext,
        metadata: [String: String],
        file: String,
        function: String,
        line: Int
    ) async
}
