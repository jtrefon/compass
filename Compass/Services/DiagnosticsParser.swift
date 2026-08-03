import Foundation

struct DiagnosticsParser {
    static func parseXcodebuildLine(_ line: String) -> Diagnostic? {
        // Typical formats:
        // /abs/path/File.swift:42:13: error: message
        // relative/path/File.swift:42: warning: message
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split into at most 5 parts: path, line, colOrSeverity, maybeSeverity, message
        // We'll do a conservative parse based on ':' separators.
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }

        func intAt(_ idx: Int) -> Int? {
            let segment = parts[idx].trimmingCharacters(in: .whitespaces)
            return Int(segment)
        }

        // Find first numeric segment to treat as line.
        // This allows paths with ':' (rare on macOS) but keeps behavior predictable.
        var lineIndex: Int?
        for index in 1..<(parts.count - 2) {
            if intAt(index) != nil {
                lineIndex = index
                break
            }
        }
        guard let li = lineIndex else { return nil }
        guard let lineNo = intAt(li) else { return nil }

        let path = parts[0..<li].joined(separator: ":").trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }

        var column: Int?
        var severityIndex = li + 1
        if li + 1 < parts.count, let col = intAt(li + 1) {
            column = col
            severityIndex = li + 2
        }

        guard severityIndex < parts.count else { return nil }
        let sevRaw = parts[severityIndex].trimmingCharacters(in: .whitespaces).lowercased()
        let severity: DiagnosticSeverity
        if sevRaw.contains("error") {
            severity = .error
        } else if sevRaw.contains("warning") {
            severity = .warning
        } else {
            return nil
        }

        let messageStart = min(severityIndex + 1, parts.count)
        let message = parts[messageStart...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return nil }

        // Normalize to relative-ish path string: if absolute, keep full for now.
        return Diagnostic(relativePath: path, line: lineNo, column: column, severity: severity, message: message)
    }

    static func parseOutputChunk(_ chunk: String) -> [Diagnostic] {
        chunk
            .split(whereSeparator: \.isNewline)
            .compactMap { parseXcodebuildLine(String($0)) }
    }
}
