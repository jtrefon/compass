import Foundation

@available(*, deprecated, message: "Use PlanTool's structured TaskPlan instead. Legacy markdown checklist system.")
struct PlanChecklistProgress {
    let completed: Int
    let total: Int

    var percentage: Int {
        guard total > 0 else { return 0 }
        return Int((Double(completed) / Double(total) * 100).rounded())
    }

    var isComplete: Bool {
        total > 0 && completed >= total
    }
}

@available(*, deprecated, message: "Use PlanTool's structured TaskPlan instead. Legacy markdown checklist system.")
enum PlanChecklistTracker {
    static func progress(in plan: String) -> PlanChecklistProgress {
        let statuses = checklistStatuses(in: plan)
        let total = statuses.count
        let completed = statuses.filter { $0 }.count
        return PlanChecklistProgress(completed: completed, total: total)
    }

    static func markNextPendingItemCompleted(in plan: String) -> String? {
        let lines = plan.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var updatedLines: [String] = []
        var marked = false

        for line in lines {
            guard !marked else {
                updatedLines.append(line)
                continue
            }

            if let markerRange = pendingChecklistMarkerRange(in: line) {
                var updatedLine = line
                updatedLine.replaceSubrange(markerRange, with: "[x]")
                updatedLines.append(updatedLine)
                marked = true
            } else {
                updatedLines.append(line)
            }
        }

        return marked ? updatedLines.joined(separator: "\n") : nil
    }

    static func markAllPendingItemsCompleted(in plan: String) -> String? {
        let lines = plan.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var updatedLines: [String] = []
        var changed = false

        for line in lines {
            if let markerRange = pendingChecklistMarkerRange(in: line) {
                var updatedLine = line
                updatedLine.replaceSubrange(markerRange, with: "[x]")
                updatedLines.append(updatedLine)
                changed = true
            } else {
                updatedLines.append(line)
            }
        }

        return changed ? updatedLines.joined(separator: "\n") : nil
    }

    private static func checklistStatuses(in plan: String) -> [Bool] {
        plan.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("- ") || text.hasPrefix("* ") else { return nil }
            if text.contains("[x]") || text.contains("[X]") { return true }
            if text.contains("[ ]") { return false }
            return nil
        }
    }

    private static func pendingChecklistMarkerRange(in line: String) -> Range<String.Index>? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        return line.range(of: "[ ]")
    }
}
