import Foundation

/// Owns the FIM model lifecycle (FIM_Spec.md UC-6, §5.5 "pre-warm on file
/// focus").
///
/// The 1.5B FIM model (~1GB MLX pool) is **unloaded by default**. It is
/// loaded ONLY while the cursor is on source code (debounced, so a quick
/// click-through does not churn the allocator), and evicted the moment the
/// cursor leaves source code or a chat run begins. A chat generation already
/// evicts FIM via the MLX memory gate; this controller keeps the warm state
/// coherent so the completion model never contends with the chat model for
/// unified memory (16GB M4: model 2.3GB + KV + FIM 1GB is the difference
/// between decoding at ~14 tps and thrashing the compressor).
@MainActor
final class FIMLifecycleController {
    static let shared = FIMLifecycleController()

    /// Posted whenever the FIM model's loaded state changes (the status-bar
    /// indicator shows "AC OK" only when the model is actually warm — the
    /// previous indicator claimed availability from "installed" alone, which
    /// stayed green while FIM was unloaded).
    static let stateDidChange = Notification.Name("FIMLifecycleStateDidChange")

    /// Single provider instance owned here so the warm/unload state is global
    /// (the engine and variant pool must share the same service).
    let provider = AIServiceInlineCompletionProvider()

    private var cursorInSourceCode = false
    private var chatRunActive = false
    private var warmTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// After a chat run ends, FIM stays COLD for this window: agent sessions
    /// send repeatedly (each send evicts FIM via the MLX memory gate), so an
    /// immediate re-warm produces a load→evict→load sawtooth (measured:
    /// ~1.5GB swings + 9s lock waits while typing mid-agent-run). The user's
    /// next keystroke pays a 1.2-1.9s cold load after the cooldown — the
    /// first completion after a long agent burst is the only cost.
    private static let chatRunCooldown: TimeInterval = 60
    private var lastChatRunEndedAt = Date.distantPast

    private var warmEligible: Bool {
        cursorInSourceCode && !chatRunActive && Date().timeIntervalSince(lastChatRunEndedAt) > Self.chatRunCooldown
    }

    private init() {}

    var isWarm: Bool { provider.isWarm }

    /// Cursor activity signal from the editor (selection changes). Only
    /// transitions matter; continuous typing in the same file is a no-op.
    func notifyCursorActivity(inSourceCode: Bool) {
        let target = inSourceCode && !chatRunActive
        guard target != cursorInSourceCode else { return }
        cursorInSourceCode = target

        if target {
            warmTask?.cancel()
            debounceTask?.cancel()
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, self.warmEligible else { return }
                await self.warm()
            }
        } else {
            warmTask?.cancel()
            debounceTask?.cancel()
            Task {
                guard await self.provider.unloadIfWarm() else { return }
                self.publishUnloadedState()
                await AIToolTraceLogger.shared.log(type: "fim.unload", data: [
                    "reason": "cursor_left_source",
                    "modelId": LocalModelCatalog.fimModel.id
                ])
            }
        }
    }

    /// A chat send started (local or cloud) — FIM must yield.
    func chatRunBegan() {
        chatRunActive = true
        warmTask?.cancel()
        debounceTask?.cancel()
        Task {
            guard await provider.unloadIfWarm() else { return }
            self.publishUnloadedState()
            await AIToolTraceLogger.shared.log(type: "fim.unload", data: [
                "reason": "chat_run_started",
                "modelId": LocalModelCatalog.fimModel.id
            ])
        }
    }

    /// A chat send finished — re-warm if the cursor is still on source code,
    /// respecting the cooldown (avoids the load→evict→load sawtooth during
    /// agent sessions).
    func chatRunEnded() {
        chatRunActive = false
        lastChatRunEndedAt = Date()
        if cursorInSourceCode {
            debounceTask?.cancel()
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, self.warmEligible else { return }
                await self.warm()
            }
        }
    }

    private func warm() async {
        guard !provider.isWarm else { return }
        let start = ContinuousClock.now
        await provider.warm()
        let loadMs = Int(Int64(start.duration(to: .now).components.attoseconds / 1_000_000_000) / 1_000_000)
        await AIToolTraceLogger.shared.log(type: "fim.warm", data: [
            "loadMs": loadMs,
            "modelId": LocalModelCatalog.fimModel.id
        ])
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil, userInfo: ["isWarm": true])
    }

    private func publishUnloadedState() {
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil, userInfo: ["isWarm": false])
    }
}