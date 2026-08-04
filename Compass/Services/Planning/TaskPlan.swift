import Foundation

// MARK: - Core Types

/// The domain of work — keeps the plan structure agnostic while informing the model how to approach the task.
enum PlanDomain: String, Codable, Sendable, CaseIterable {
    case architecture
    case implementation
    case research
    case refactor
    case analysis
    case design
    case investigation
}

/// Status of a single plan item — tracked by the framework, not by the model.
enum ItemStatus: String, Codable, Sendable {
    case pending
    case active
    case completed
    case blocked
}

/// A single unit of work — carries enough context for the model to recover after compression.
struct PlanItem: Codable, Sendable, Identifiable {
    let id: String
    let description: String          // WHAT to do (actionable, domain-specific)
    let purpose: String              // WHY — what value this delivers
    let context: [String]            // WHERE/WHAT — files, URLs, concepts, references
    let doneCriteria: String         // HOW to verify completion
    var status: ItemStatus           // pending | active | completed | blocked
    var summary: String?             // Model's sign-off summary when done
    var blockedReason: String?       // If status == blocked
}

/// The complete plan for a conversation — persisted and survives context compression.
struct TaskPlan: Codable, Sendable {
    let id: String                   // UUID — links plan to conversation
    let goal: String                 // WHAT we're achieving
    let value: String                // WHY this matters — what success looks like
    let domain: PlanDomain           // The domain of work
    let mode: AIMode                 // coder or agent
    var items: [PlanItem]            // Ordered list of all tasks
    let createdAt: Date
    var completedAt: Date?
    var currentIndex: Int            // Which item the model is working on

    /// The currently active item, if any.
    var activeItem: PlanItem? {
        guard currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    /// Progress as a fraction (0.0 - 1.0).
    var progress: Double {
        guard !items.isEmpty else { return 0 }
        let completed = items.filter { $0.status == .completed || $0.status == .blocked }.count
        return Double(completed) / Double(items.count)
    }

    /// Whether all items are complete or blocked.
    var isComplete: Bool {
        items.allSatisfy { $0.status == .completed || $0.status == .blocked }
    }

    /// Markdown representation for backward compatibility (UI rendering, legacy systems).
    var markdown: String {
        var lines: [String] = ["# Implementation Plan", "", "**Goal:** \(goal)", "**Value:** \(value)", "**Domain:** \(domain.rawValue)", ""]
        for (index, item) in items.enumerated() {
            let statusMarker: String
            switch item.status {
            case .pending, .active: statusMarker = "[ ]"
            case .completed: statusMarker = "[x]"
            case .blocked: statusMarker = "[!]"
            }
            lines.append("\(index + 1). \(statusMarker) \(item.description)")
            if let summary = item.summary {
                lines.append("    - Summary: \(summary)")
            }
            if let blocked = item.blockedReason {
                lines.append("    - Blocked: \(blocked)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Complete the item at the given index with a summary and mark it completed.
    /// Does NOT advance to the next item — call `activateNextPending()` separately.
    mutating func completeItem(at index: Int, summary: String) {
        guard index < items.count else { return }
        items[index].status = .completed
        items[index].summary = summary
    }

    /// Activate the next pending item and return its index, or nil if none remain.
    /// Scans for the next `.pending` item (skipping blocked items).
    @discardableResult
    mutating func activateNextPending() -> Int? {
        guard let next = items.firstIndex(where: { $0.status == .pending }) else {
            return nil
        }
        items[next].status = .active
        return next
    }

    /// Advance to the next pending item. Returns false if already at end.
    /// Uses `activateNextPending()` internally for consistent scanning logic.
    @discardableResult
    mutating func advance() -> Bool {
        guard currentIndex < items.count else { return false }
        items[currentIndex].status = .completed
        currentIndex += 1
        if let next = activateNextPending() {
            currentIndex = next
        }
        if isComplete {
            completedAt = Date()
        }
        return currentIndex < items.count
    }

    /// Mark the current item as blocked.
    mutating func blockCurrent(reason: String) {
        guard currentIndex < items.count else { return }
        items[currentIndex].status = .blocked
        items[currentIndex].blockedReason = reason
    }

    /// Mark all remaining items as blocked (plan abandoned).
    mutating func abandonAll() {
        for i in currentIndex..<items.count {
            items[i].status = .blocked
            if items[i].blockedReason == nil {
                items[i].blockedReason = "Abandoned — prior task blocked"
            }
        }
        completedAt = Date()
    }
}
