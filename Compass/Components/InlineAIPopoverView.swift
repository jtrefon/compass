import SwiftUI

@MainActor
final class InlineAIPopoverManager: ObservableObject {
    static let disabled = InlineAIPopoverManager(
        aiService: nil,
        projectRootProvider: { nil }
    )

    @Published var isVisible: Bool = false
    @Published var question: String = ""
    @Published var answer: String = ""
    @Published var isProcessing: Bool = false
    @Published var error: String?

    var anchorRect: CGRect = .zero
    var paneID: FileEditorStateManager.PaneID = .primary

    private let aiService: AIService?
    private let projectRootProvider: () -> URL?

    init(
        aiService: AIService?,
        projectRootProvider: @escaping () -> URL?
    ) {
        self.aiService = aiService
        self.projectRootProvider = projectRootProvider
    }

    func present(anchor: CGRect, paneID: FileEditorStateManager.PaneID) {
        anchorRect = anchor
        self.paneID = paneID
        question = ""
        answer = ""
        error = nil
        isVisible = true
    }

    func dismiss() {
        isVisible = false
        question = ""
        answer = ""
        error = nil
        isProcessing = false
    }

    func submitQuestion(context: String?) {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isProcessing = true
        error = nil
        answer = ""

        Task { @MainActor in
            let projectRoot = projectRootProvider() ?? FileManager.default.temporaryDirectory
            let userQuestion = question
            question = ""

            let request = AIServiceHistoryRequest(
                messages: [
                    ChatMessage(role: .user, content: userQuestion)
                ],
                mediaAttachments: [],
                tools: [],
                mode: .chat,
                projectRoot: projectRoot,
                runId: UUID().uuidString,
                stage: nil,
                conversationId: nil
            )

            guard let aiService = aiService else {
                error = "AI service not available"
                isProcessing = false
                return
            }
            do {
                let response = try await aiService.sendMessageStreaming(request, runId: request.runId ?? "")
                answer = response.content ?? ""
            } catch {
                self.error = error.localizedDescription
            }
            isProcessing = false
        }
    }
}

struct InlineAIPopoverView: View {
    @ObservedObject var manager: InlineAIPopoverManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.answer.isEmpty && !manager.isProcessing {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .foregroundStyle(Color.accentColor)
                    Text("Ask about this code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Question...", text: $manager.question)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(AppConstants.Layout.spacingSm)
                    .background(
                        RoundedRectangle(cornerRadius: AppConstants.Layout.cornerSm)
                            .fill(AppConstants.Color.surfaceCard)
                    )
                    .onSubmit {
                        manager.submitQuestion(context: nil)
                    }

                HStack {
                    Spacer()
                    Button("Ask") {
                        manager.submitQuestion(context: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(manager.question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if manager.isProcessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Thinking...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !manager.answer.isEmpty {
                ScrollView {
                    Text(manager.answer)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }

            if let error = manager.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AppConstants.Color.alertError)
            }
        }
        .padding(AppConstants.Layout.spacingMd)
        .frame(width: 320)
        .nativeGlassBackground(.popover, cornerRadius: AppConstants.Layout.cornerLg, showBorder: true)
        .overlay(alignment: .topTrailing) {
            Button(action: { manager.dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(4)
        }
    }
}
