import Foundation
@testable import Compass

/// Performance metrics for local model inference testing
struct InferencePerformanceMetrics: Sendable {
    let testId: String
    let modelId: String
    let configurationLabel: String
    let contextLength: Int
    let maxKVSize: Int
    let maxOutputTokens: Int
    let prefillStepSize: Int
    let conversationTurn: Int
    let promptTokenCount: Int
    let outputTokenCount: Int
    let timeToFirstToken: TimeInterval
    let totalDuration: TimeInterval
    let peakMemoryMB: UInt64
    let mlxLoadMilliseconds: Int?
    let mlxPromptTokenCount: Int?
    let mlxPromptMilliseconds: Int?
    let mlxPromptTokensPerSecond: Double?
    let mlxGenerationTokenCount: Int?
    let mlxGenerationMilliseconds: Int?
    let mlxGenerationTokensPerSecond: Double?
    let rssBeforeLoadMB: Int?
    let rssAfterLoadMB: Int?
    let rssAfterGenerationMB: Int?
    let timestamp: Date
    
    var tokensPerSecond: Double {
        guard totalDuration > 0 else { return 0 }
        return Double(outputTokenCount) / totalDuration
    }
    
    var promptTokensPerSecond: Double {
        guard totalDuration > 0 else { return 0 }
        return Double(promptTokenCount) / totalDuration
    }

    var mlxGenerationTokensPerSecondEffective: Double {
        guard let tokens = mlxGenerationTokenCount,
              let durationMS = mlxGenerationMilliseconds,
              durationMS > 0 else {
            return 0
        }
        return Double(tokens) / (Double(durationMS) / 1000.0)
    }
    
    /// Create a summary string for logging
    var summary: String {
        """
        [Inference Metrics - \(testId)]
        Model: \(modelId)
        Config: \(configurationLabel)
        Turn: \(conversationTurn)
        Context: \(contextLength)
        Max KV: \(maxKVSize)
        Max Output: \(maxOutputTokens)
        Prefill Step: \(prefillStepSize)
        Prompt Tokens: \(promptTokenCount)
        Output Tokens: \(outputTokenCount)
        Time to First Token: \(String(format: "%.3f", timeToFirstToken))s
        Total Duration: \(String(format: "%.3f", totalDuration))s
        Visible Tokens/Second: \(String(format: "%.1f", tokensPerSecond))
        MLX Load: \(mlxLoadMilliseconds ?? 0)ms
        MLX Prompt: tokens=\(mlxPromptTokenCount ?? 0) ms=\(mlxPromptMilliseconds ?? 0) tps=\(String(format: "%.1f", mlxPromptTokensPerSecond ?? 0))
        MLX Generate: tokens=\(mlxGenerationTokenCount ?? 0) ms=\(mlxGenerationMilliseconds ?? 0) tps=\(String(format: "%.1f", mlxGenerationTokensPerSecond ?? 0))
        RSS: before_load=\(rssBeforeLoadMB ?? 0)MB after_load=\(rssAfterLoadMB ?? 0)MB after_gen=\(rssAfterGenerationMB ?? 0)MB
        Peak Memory: \(peakMemoryMB)MB
        """
    }
    
    /// CSV header for metrics export
    static var csvHeader: String {
        "test_id,model_id,config_label,context_length,max_kv_size,max_output_tokens,prefill_step_size,turn,prompt_tokens,output_tokens,ttft_s,total_s,visible_tokens_per_sec,peak_memory_mb,mlx_load_ms,mlx_prompt_tokens,mlx_prompt_ms,mlx_prompt_tps,mlx_gen_tokens,mlx_gen_ms,mlx_gen_tps,rss_before_load_mb,rss_after_load_mb,rss_after_gen_mb,timestamp"
    }
    
    /// CSV row for metrics export
    var csvRow: String {
        "\(testId),\(modelId),\(configurationLabel),\(contextLength),\(maxKVSize),\(maxOutputTokens),\(prefillStepSize),\(conversationTurn),\(promptTokenCount),\(outputTokenCount),\(String(format: "%.3f", timeToFirstToken)),\(String(format: "%.3f", totalDuration)),\(String(format: "%.1f", tokensPerSecond)),\(peakMemoryMB),\(mlxLoadMilliseconds ?? 0),\(mlxPromptTokenCount ?? 0),\(mlxPromptMilliseconds ?? 0),\(String(format: "%.1f", mlxPromptTokensPerSecond ?? 0)),\(mlxGenerationTokenCount ?? 0),\(mlxGenerationMilliseconds ?? 0),\(String(format: "%.1f", mlxGenerationTokensPerSecond ?? 0)),\(rssBeforeLoadMB ?? 0),\(rssAfterLoadMB ?? 0),\(rssAfterGenerationMB ?? 0),\(ISO8601DateFormatter().string(from: timestamp))"
    }
}

/// Collector for aggregating performance metrics across test runs
actor InferenceMetricsCollector {
    static let shared = InferenceMetricsCollector()
    
    private var metrics: [InferencePerformanceMetrics] = []
    private var currentTestId: String?
    private var turnCount: Int = 0
    
    private init() {}
    
    func startTest(testId: String) {
        currentTestId = testId
        turnCount = 0
    }
    
    func endTest() {
        currentTestId = nil
        turnCount = 0
    }
    
    func recordMetrics(_ metric: InferencePerformanceMetrics) {
        metrics.append(metric)
    }
    
    func incrementTurn() -> Int {
        turnCount += 1
        return turnCount
    }
    
    func getAllMetrics() -> [InferencePerformanceMetrics] {
        metrics
    }
    
    func getMetrics(forTestId testId: String) -> [InferencePerformanceMetrics] {
        metrics.filter { $0.testId == testId }
    }
    
    func clearMetrics() {
        metrics.removeAll()
    }
    
    /// Export all metrics as CSV
    func exportCSV() -> String {
        var lines = [InferencePerformanceMetrics.csvHeader]
        lines.append(contentsOf: metrics.map { $0.csvRow })
        return lines.joined(separator: "\n")
    }
    
    /// Calculate aggregate statistics
    func aggregateStats() -> AggregateStats? {
        guard !metrics.isEmpty else { return nil }
        
        let totalTokens = metrics.reduce(0) { $0 + $1.outputTokenCount }
        let totalDuration = metrics.reduce(0.0) { $0 + $1.totalDuration }
        let avgTokensPerSecond = totalDuration > 0 ? Double(totalTokens) / totalDuration : 0
        let totalMLXGenerationTokens = metrics.reduce(0) { $0 + ($1.mlxGenerationTokenCount ?? 0) }
        let totalMLXGenerationDuration = metrics.reduce(0.0) { partial, metric in
            partial + Double(metric.mlxGenerationMilliseconds ?? 0) / 1000.0
        }
        let avgMLXGenerationTokensPerSecond = totalMLXGenerationDuration > 0
            ? Double(totalMLXGenerationTokens) / totalMLXGenerationDuration
            : 0
        let avgTimeToFirstToken = metrics.reduce(0.0) { $0 + $1.timeToFirstToken } / Double(metrics.count)
        let peakMemory = metrics.map(\.peakMemoryMB).max() ?? 0
        
        return AggregateStats(
            totalInferences: metrics.count,
            totalTokens: totalTokens,
            totalDuration: totalDuration,
            avgTokensPerSecond: avgTokensPerSecond,
            totalMLXGenerationTokens: totalMLXGenerationTokens,
            totalMLXGenerationDuration: totalMLXGenerationDuration,
            avgMLXGenerationTokensPerSecond: avgMLXGenerationTokensPerSecond,
            avgTimeToFirstToken: avgTimeToFirstToken,
            peakMemoryMB: peakMemory
        )
    }
    
    struct AggregateStats: Sendable {
        let totalInferences: Int
        let totalTokens: Int
        let totalDuration: TimeInterval
        let avgTokensPerSecond: Double
        let totalMLXGenerationTokens: Int
        let totalMLXGenerationDuration: TimeInterval
        let avgMLXGenerationTokensPerSecond: Double
        let avgTimeToFirstToken: TimeInterval
        let peakMemoryMB: UInt64
        
        var summary: String {
            """
            [Aggregate Performance Stats]
            Total Inferences: \(totalInferences)
            Total Visible Tokens: \(totalTokens)
            Total Duration: \(String(format: "%.2f", totalDuration))s
            Avg Visible Tokens/Second: \(String(format: "%.1f", avgTokensPerSecond))
            Total MLX Generation Tokens: \(totalMLXGenerationTokens)
            Total MLX Generation Duration: \(String(format: "%.2f", totalMLXGenerationDuration))s
            Avg MLX Generation Tokens/Second: \(String(format: "%.1f", avgMLXGenerationTokensPerSecond))
            Avg Time to First Token: \(String(format: "%.3f", avgTimeToFirstToken))s
            Peak Memory: \(peakMemoryMB)MB
            """
        }
    }
}

/// Helper for measuring inference performance
struct InferenceTimer {
    private let startTime: Date
    private var firstTokenTime: Date?
    private let startMemory: UInt64
    
    init() {
        self.startTime = Date()
        self.startMemory = Self.reportMemory()
    }
    
    mutating func recordFirstToken() {
        if firstTokenTime == nil {
            firstTokenTime = Date()
        }
    }
    
    func finalize(
        testId: String,
        modelId: String,
        inferenceConfiguration: LocalModelInferenceConfiguration,
        turn: Int,
        promptTokens: Int,
        outputTokens: Int,
        performanceSnapshot: LocalModelGenerationPerformanceSnapshot?
    ) -> InferencePerformanceMetrics {
        let endTime = Date()
        let endMemory = Self.reportMemory()
        let effectiveConfiguration = performanceSnapshot?.inferenceConfiguration ?? inferenceConfiguration
        
        return InferencePerformanceMetrics(
            testId: testId,
            modelId: modelId,
            configurationLabel: effectiveConfiguration.label,
            contextLength: effectiveConfiguration.contextLength,
            maxKVSize: effectiveConfiguration.maxKVSize,
            maxOutputTokens: effectiveConfiguration.maxOutputTokens,
            prefillStepSize: effectiveConfiguration.prefillStepSize,
            conversationTurn: turn,
            promptTokenCount: promptTokens,
            outputTokenCount: outputTokens,
            timeToFirstToken: firstTokenTime?.timeIntervalSince(startTime) ?? 0,
            totalDuration: endTime.timeIntervalSince(startTime),
            peakMemoryMB: max(startMemory, endMemory),
            mlxLoadMilliseconds: performanceSnapshot?.loadMilliseconds,
            mlxPromptTokenCount: performanceSnapshot?.promptTokenCount,
            mlxPromptMilliseconds: performanceSnapshot?.promptMilliseconds,
            mlxPromptTokensPerSecond: performanceSnapshot?.promptTokensPerSecond,
            mlxGenerationTokenCount: performanceSnapshot?.generationTokenCount,
            mlxGenerationMilliseconds: performanceSnapshot?.generationMilliseconds,
            mlxGenerationTokensPerSecond: performanceSnapshot?.generationTokensPerSecond,
            rssBeforeLoadMB: performanceSnapshot?.rssBeforeLoadMB,
            rssAfterLoadMB: performanceSnapshot?.rssAfterLoadMB,
            rssAfterGenerationMB: performanceSnapshot?.rssAfterGenerationMB,
            timestamp: startTime
        )
    }
    
    static func reportMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return result == KERN_SUCCESS ? info.resident_size / 1_048_576 : 0
    }
}
