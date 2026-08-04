import Foundation

extension EditorPaneStateManager {
    func selectLine(_ line: Int) {
        let target = max(1, line)
        let ns = editorContent as NSString
        let lines = ns.components(separatedBy: "\n")
        if lines.isEmpty {
            selectedRange = NSRange(location: 0, length: 0)
            return
        }

        var currentLine = 1
        var location = 0
        for idx in 0..<lines.count {
            if currentLine == target {
                break
            }
            location += (lines[idx] as NSString).length
            location += 1
            currentLine += 1
        }

        location = max(0, min(location, ns.length))
        selectedRange = NSRange(location: location, length: 0)
    }
}
