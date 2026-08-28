import SwiftUI
import Foundation

struct ReasoningOutcomeMessageView: View {
    let message: ChatMessage
    var fontSize: Double

    private var outcome: ReasoningOutcome? {
        Self.parse(from: message.content)
    }

    var body: some View {
        if let outcome {
            VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
                header

                outcomeRow(title: "Plan Delta", value: outcome.planDelta)
                outcomeRow(title: "Next Action", value: outcome.nextAction)
                outcomeRow(title: "Known Risks", value: outcome.knownRisks)

                HStack(spacing: AppConstants.Layout.spacingSm) {
                    Text("Delivery")
                        .font(.system(size: CGFloat(max(10, fontSize - 2)), weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(outcome.deliveryState == .done ? "Done" : "Needs Work")
                        .font(.system(size: CGFloat(max(9, fontSize - 3)), weight: .semibold))
                        .padding(.horizontal, AppConstants.Layout.spacingSm)
                        .padding(.vertical, AppConstants.Layout.spacingXXS)
                        .background(outcome.deliveryState == .done ? AppConstants.Color.statusSuccessSubtle : AppConstants.Color.statusWarningSubtle)
                        .foregroundColor(outcome.deliveryState == .done ? AppConstants.Color.statusSuccess : AppConstants.Color.statusWarning)
                        .cornerRadius(AppConstants.Layout.cornerSm)
                }
            }
            .padding(.horizontal, AppConstants.Layout.spacingMd)
            .padding(.vertical, AppConstants.Layout.spacingSm)
            .nativeGlassBackground(.panel, cornerRadius: AppConstants.Layout.cornerLg)
        }
    }

    private var header: some View {
        HStack(spacing: AppConstants.Layout.spacingSm) {
            Image(systemName: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Reasoning Outcome")
                .font(.system(size: CGFloat(max(10, fontSize - 1)), weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func outcomeRow(title: String, value: String?) -> some View {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: AppConstants.Layout.spacingXXS) {
                Text(title)
                    .font(.system(size: CGFloat(max(9, fontSize - 4)), weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(trimmed)
                    .font(.system(size: CGFloat(max(10, fontSize - 2))))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    static func parse(from content: String) -> ReasoningOutcome? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ReasoningOutcome:") else { return nil }

        var planDelta: String?
        var nextAction: String?
        var knownRisks: String?
        var deliveryState: ReasoningOutcomeDeliveryState = .needs_work

        for line in trimmed.split(separator: "\n").map(String.init) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "plan_delta":
                planDelta = value.isEmpty ? nil : value
            case "next_action":
                nextAction = value.isEmpty ? nil : value
            case "known_risks":
                knownRisks = value.isEmpty ? nil : value
            case "delivery_state":
                deliveryState = ReasoningOutcomeDeliveryState(rawValue: value) ?? .needs_work
            default:
                break
            }
        }

        return ReasoningOutcome(
            planDelta: planDelta,
            nextAction: nextAction,
            knownRisks: knownRisks,
            deliveryState: deliveryState
        )
    }
}
