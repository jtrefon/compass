//
//  ToolExecutionMessageView.swift
//  Compass
//
//  Created by AI Assistant on 12/01/2026.
//

import SwiftUI
import Foundation

/// View for displaying tool execution messages with status and progress
struct ToolExecutionMessageView: View {
    let message: ChatMessage
    var fontSize: Double
    var fontFamily: String

    @ObservedObject private var timeoutCenter = ToolTimeoutCenter.shared

    @State private var isExpanded = false

    private var envelope: ToolExecutionEnvelope? {
        ToolExecutionEnvelope.decode(from: message.content)
    }

    private var displayToolName: String {
        message.toolName ?? envelope?.toolName ?? localized("tool.default_name")
    }

    private var displayTargetFile: String? {
        message.targetFile ?? envelope?.targetFile
    }

    private var displayStatus: ToolExecutionStatus? {
        message.toolStatus ?? envelope?.status
    }

    private var displayPayload: String {
        let directContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let envelope else { return directContent }

        if let payload = envelope.payload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty {
            return payload
        }
        return envelope.message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewContent: String? {
        guard let preview = envelope?.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty else {
            return nil
        }
        return preview
    }

    private var displayCommand: String? {
        guard displayToolName == "run_command", let payload = envelope?.payload else { return nil }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["command"] as? String
    }

    private var displayExitCode: Int32? {
        guard displayToolName == "run_command", let payload = envelope?.payload else { return nil }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["exit_code"] as? Int32
    }

    private var displayOutputTail: String? {
        guard displayToolName == "run_command", let payload = envelope?.payload else { return nil }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["output_tail"] as? String
    }

    private var isCommandTool: Bool {
        displayToolName == "run_command"
    }

    private var isFileMutationTool: Bool {
        ["write", "edit", "rm"].contains(displayToolName)
    }

    private var isReadFileTool: Bool {
        displayToolName == "read"
    }

    private var readFileRangeLabel: String? {
        guard let previewContent else { return nil }
        let lines = previewContent.split(separator: "\n").map(String.init)
        return lines.first(where: { $0.hasPrefix("Lines:") || $0.hasPrefix("From line:") })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (Always Visible)
            toolExecutionHeader

            // Content (Expandable)
            if isExpanded || displayStatus == .executing {
                toolExecutionContent
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: AppConstants.Layout.cornerLg))
        .overlay(
            RoundedRectangle(cornerRadius: AppConstants.Layout.cornerLg)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Private Components

    private var toolExecutionHeader: some View {
        HStack(spacing: AppConstants.Layout.spacingSm) {
            statusIcon

            VStack(alignment: .leading, spacing: AppConstants.Layout.spacingXXS) {
                if displayToolName == "run_command", let cmd = displayCommand {
                    Text(cmd)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text(displayToolName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                }

                if let file = displayTargetFile {
                    Text(file)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if isReadFileTool, let readFileRangeLabel {
                    Text(readFileRangeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if displayStatus == .executing {
                    let trimmed = displayPayload.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let lastLine = trimmed.split(
                            separator: "\n",
                            omittingEmptySubsequences: false
                        ).last.map(String.init) ?? trimmed
                        Text(lastLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                if displayToolName == "run_command", let code = displayExitCode, displayStatus == .completed {
                    Text(code == 0 ? "Exit 0" : "Exit \(code)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(code == 0 ? AppConstants.Color.statusSuccess : AppConstants.Color.statusError)
                }
            }

            Spacer()

            if displayStatus == .executing,
               let toolCallId = message.toolCallId,
               timeoutCenter.activeToolCallId == toolCallId {
                HStack(spacing: AppConstants.Layout.spacingSm) {
                    if let seconds = timeoutCenter.countdownSeconds {
                        Text("\(seconds)s")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Button {
                        timeoutCenter.cancelActiveToolNow()
                    } label: {
                        Image(systemName: "xmark.octagon")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Kill tool")
                }
            }

            // Expand/Collapse button
            if displayStatus != .executing &&
                !displayPayload.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, AppConstants.Layout.spacingMd)
        .padding(.vertical, AppConstants.Layout.spacingSm)
    }

    private var toolExecutionContent: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
            if displayStatus == .executing {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 16, height: 16)
            }

            if let previewContent {
                VStack(alignment: .leading, spacing: AppConstants.Layout.spacingXS) {
                    Text("Preview")
                        .font(.system(size: CGFloat(max(9, fontSize - 4)), weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(previewContent)
                            .font(.system(size: CGFloat(max(10, fontSize - 2)), design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                }
            }

            let content = displayPayload.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !content.isEmpty {
                if isCommandTool {
                    commandPreview(content)
                } else if isReadFileTool {
                    readFilePreview(content)
                } else if isFileMutationTool {
                    fileMutationPreview(content)
                } else {
                    genericPayloadPreview(content)
                }
            }
        }
        .padding(.horizontal, AppConstants.Layout.spacingMd)
        .padding(.bottom, AppConstants.Layout.spacingSm)
    }

    private func genericPayloadPreview(_ content: String) -> some View {
        ScrollView {
            Text(content)
                .font(.system(size: CGFloat(max(10, fontSize - 2)), design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 220)
    }

    private func fileMutationPreview(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
            HStack(spacing: AppConstants.Layout.spacingSm) {
                Text(fileOperationLabel)
                    .font(.system(size: CGFloat(max(9, fontSize - 4)), weight: .semibold))
                    .padding(.horizontal, AppConstants.Layout.spacingSm)
                    .padding(.vertical, AppConstants.Layout.spacingXXS)
                    .background(AppConstants.Color.statusActive.opacity(0.12))
                    .cornerRadius(AppConstants.Layout.cornerSm)

                if let target = displayTargetFile {
                    Text(target)
                        .font(.system(size: CGFloat(max(9, fontSize - 4))))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            genericPayloadPreview(content)
        }
    }

    private func readFilePreview(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
            HStack(spacing: AppConstants.Layout.spacingSm) {
                Text("Read")
                    .font(.system(size: CGFloat(max(9, fontSize - 4)), weight: .semibold))
                    .padding(.horizontal, AppConstants.Layout.spacingSm)
                    .padding(.vertical, AppConstants.Layout.spacingXXS)
                    .background(AppConstants.Color.statusSuccessSubtle)
                    .cornerRadius(AppConstants.Layout.cornerSm)

                if let target = displayTargetFile {
                    Text(target)
                        .font(.system(size: CGFloat(max(9, fontSize - 4))))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let readFileRangeLabel {
                Text(readFileRangeLabel)
                    .font(.system(size: CGFloat(max(9, fontSize - 4))))
                    .foregroundStyle(.secondary)
            }

            genericPayloadPreview(content)
        }
    }

    private func commandPreview(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
            if let cmd = displayCommand {
                Text("$ \(cmd)")
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            if let tail = displayOutputTail, !tail.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(tail)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .background(AppConstants.Color.surfaceEditor)
                .cornerRadius(AppConstants.Layout.cornerSm)
            } else {
                genericPayloadPreview(content)
            }
        }
    }

    private var fileOperationLabel: String {
        switch displayToolName {
        case "write", "write_file", "create_file":
            return "Write"
        case "edit", "replace_in_file":
            return "Edit"
        case "rm", "delete_file":
            return "Delete"
        default:
            return "File"
        }
    }

    private var statusIcon: some View {
        Group {
            switch displayStatus {
            case .some(.executing):
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 16, height: 16)
            case .some(.completed):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppConstants.Color.statusSuccess)
                    .font(.body)
            case .some(.failed):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppConstants.Color.statusError)
                    .font(.body)
            case .none:
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                    .font(.body)
            }
        }
        .frame(width: 16, height: 16)
    }
}

