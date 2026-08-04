import Foundation

/// Adapter that provides two file-editing modes as the `edit` AITool for the
/// v1 ToolLoopHandler pipeline:
///
/// 1. **old_string / new_string** (preferred) — locate-and-replace. The
///    model does NOT need to read the file first; the tool locates the
///    match itself. Refuses ambiguous matches unless `replace_all` is set.
///    This matches the industry-standard semantics used by Aider, Cline,
///    opencode, etc., and eliminates the mandatory "read + edit by line
///    range" roundtrip that inflated context usage in audit §1.
///
/// 2. **start_line / end_line / new_content** (legacy) — surgical line-range
///    replacement. Kept for backward compatibility (and for whitespace-
///    sensitive blocks the model can't quote reliably). Reads the file first
///    to obtain line numbers.
struct PatchFileToolAdapter: AITool {
    let projectRoot: URL

    let name = "edit"
    let description = "Edit an existing file. Preferred mode: pass old_string+new_string and the tool locates the match itself (no prior read required). Refuses ambiguous matches unless replace_all=true. Alternative: pass start_line+end_line+new_content for a surgical line-range edit (read the file first for line numbers)."

    var parameters: [String: Any] {
        ["type": "object", "properties": [
            "path": ["type": "string", "description": "Absolute or project-relative path to the file to patch."],
            "old_string": [
                "type": "string",
                "description": "(Preferred mode.) The exact text to locate in the file. Must match uniquely unless replace_all=true. Copy the substring precisely (including indentation and newlines) — the tool does an exact byte match."
            ],
            "new_string": [
                "type": "string",
                "description": "Replacement text for the matched occurrence(s) of old_string. Pass an empty string to delete."
            ],
            "replace_all": [
                "type": "boolean",
                "description": "If true, replace every occurrence of old_string. Default false — old_string must match exactly once."
            ],
            "start_line": ["type": "integer", "description": "1-based line where replacement begins (line-range mode)."],
            "end_line": ["type": "integer", "description": "1-based inclusive end line (line-range mode)."],
            "new_content": ["type": "string", "description": "Replacement content for the line range (line-range mode)."]
        ], "required": ["path"]]
    }

    func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        let path = raw["path"] as? String ?? ""
        let oldString = raw["old_string"] as? String
        let newString = raw["new_string"] as? String
        let replaceAll = ToolArgumentCoercion.asBool(raw["replace_all"]) ?? false
        let startLine = (raw["start_line"] as? Int) ?? 0
        let endLine = (raw["end_line"] as? Int) ?? 0
        let newContent = raw["new_content"] as? String ?? ""

        let url: URL
        if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else { url = projectRoot.appendingPathComponent(path) }

        let fm = FileManager.default
        guard let data = fm.contents(atPath: url.path) else {
            return "status: error\nmessage: File not found: \(path)\nerror_code: FILE_NOT_FOUND\nrecoverable: true"
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return "status: error\nmessage: Binary file\nerror_code: BINARY_FILE\nrecoverable: false"
        }

        let hasOldString = oldString != nil && !(oldString?.isEmpty ?? true)
        let hasNewString = newString != nil
        let hasLineRange = startLine >= 1 && endLine >= startLine

        if hasOldString && hasNewString {
            return try applyOldStringMode(
                path: path,
                url: url,
                content: content,
                oldString: oldString!,
                newString: newString!,
                replaceAll: replaceAll,
                fm: fm
            )
        }

        guard hasLineRange else {
            return "status: error\nmessage: Provide either old_string+new_string (preferred) or start_line+end_line+new_content. Note: new_content ALONE is not enough — it must be paired with start_line and end_line. Got: path=\(path), old_string=\(hasOldString), new_string=\(hasNewString), line_range=\(hasLineRange).\nerror_code: MISSING_ARGUMENTS\nrecoverable: true"
        }

        return applyLineRangeMode(
            path: path,
            url: url,
            content: content,
            startLine: startLine,
            endLine: endLine,
            newContent: newContent,
            fm: fm
        )
    }

    // MARK: - old_string / new_string mode

    private func applyOldStringMode(
        path: String,
        url: URL,
        content: String,
        oldString: String,
        newString: String,
        replaceAll: Bool,
        fm: FileManager
    ) throws -> String {
        let matchCount = countOccurrences(in: content, of: oldString)

        guard matchCount > 0 else {
            return "status: error\nmessage: old_string not found in \(path). Copy the exact substring (including whitespace and newlines) from the file and retry. Common cause: leading/trailing whitespace mismatch, or your copy of the line was reformatted.\nerror_code: OLD_STRING_NOT_FOUND\nrecoverable: true"
        }
        guard matchCount == 1 || replaceAll else {
            return "status: error\nmessage: old_string matched \(matchCount) times in \(path). Include more surrounding context so it is unique, or set replace_all=true to update every occurrence.\nerror_code: AMBIGUOUS_MATCH\nrecoverable: true"
        }

        let newFull = content.replacingOccurrences(of: oldString, with: newString)
        if newFull == content {
            return "status: success\nmessage: No-op — new_string is identical to old_string in \(path)."
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data(newFull.utf8).write(to: tmp, options: .atomic)
        try fm.replaceItemAt(url, withItemAt: tmp)

        guard let vData = fm.contents(atPath: url.path),
              let vContent = String(data: vData, encoding: .utf8),
              vContent == newFull else {
            return "status: error\nmessage: Verification failed\nerror_code: VERIFICATION_FAILED\nrecoverable: true"
        }

        let diff = diffPreview(oldText: oldString, newText: newString)
        let matchPhrase = matchCount == 1 ? "1 match" : "\(matchCount) matches"
        return "status: success\nmessage: Patched \(path) (\(matchPhrase), old_string → new_string)\ncontent:\n  \(diff.replacingOccurrences(of: "\n", with: "\n  "))"
    }

    private func countOccurrences(in haystack: String, of needle: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private func diffPreview(oldText: String, newText: String) -> String {
        var lines: [String] = ["--- old_string", "+++ new_string"]
        for l in oldText.components(separatedBy: "\n") { lines.append("-\(l)") }
        for l in newText.components(separatedBy: "\n") { lines.append("+\(l)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Line-range mode (legacy, preserved)

    private func applyLineRangeMode(
        path: String,
        url: URL,
        content: String,
        startLine: Int,
        endLine: Int,
        newContent: String,
        fm: FileManager
    ) -> String {
        var lines = content.components(separatedBy: "\n")
        let total = lines.count
        guard startLine >= 1, startLine <= total, endLine >= startLine, endLine <= total else {
            return "status: error\nmessage: Invalid range \(startLine)-\(endLine), file has \(total) lines\nerror_code: INVALID_LINE_RANGE\nrecoverable: true"
        }

        let oldContent = lines[(startLine - 1)...(endLine - 1)].joined(separator: "\n")
        lines.replaceSubrange((startLine - 1)...(endLine - 1), with: [newContent])
        let newFull = lines.joined(separator: "\n")

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        do {
            try Data(newFull.utf8).write(to: tmp, options: .atomic)
            try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            return "status: error\nmessage: Write failed: \(error.localizedDescription)\nerror_code: WRITE_FAILED\nrecoverable: true"
        }

        guard let vData = fm.contents(atPath: url.path),
              let vContent = String(data: vData, encoding: .utf8),
              vContent == newFull else {
            return "status: error\nmessage: Verification failed\nerror_code: VERIFICATION_FAILED\nrecoverable: true"
        }

        var diff = "--- a (lines \(startLine)-\(endLine))\n+++ b (lines \(startLine)-\(endLine))\n"
        for l in oldContent.components(separatedBy: "\n") { diff += "-\(l)\n" }
        for l in newContent.components(separatedBy: "\n") { diff += "+\(l)\n" }

        return "status: success\nmessage: Patched \(path) (lines \(startLine)-\(endLine))\ncontent:\n  \(diff.replacingOccurrences(of: "\n", with: "\n  "))"
    }
}
