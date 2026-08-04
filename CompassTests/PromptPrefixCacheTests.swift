import XCTest
@testable import Compass

final class PromptPrefixCacheTests: XCTestCase {
    var cache: PromptPrefixCache!
    
    override func setUp() async throws {
        cache = PromptPrefixCache()
    }
    
    override func tearDown() async throws {
        await cache.clearAll()
    }
    
    // MARK: - Basic Cache Operations
    
    func testStoreAndRetrievePrefix() async throws {
        let conversationId = "test-conv-1"
        let modelId = "test-model-1"
        let systemPrompt = "You are a helpful assistant."
        
        await cache.storePrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        let retrieved = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.conversationId, conversationId)
        XCTAssertEqual(retrieved?.modelId, modelId)
        XCTAssertEqual(retrieved?.systemPrompt, systemPrompt)
    }
    
    func testCacheMissReturnsNil() async throws {
        let retrieved = await cache.getCachedPrefix(
            conversationId: "nonexistent",
            modelId: "nonexistent",
            systemPrompt: "test",
            tools: nil,
            mode: nil
        )
        
        XCTAssertNil(retrieved)
    }
    
    func testCacheInvalidatesOnSystemPromptChange() async throws {
        let conversationId = "test-conv-2"
        let modelId = "test-model-1"
        let originalPrompt = "You are a helpful assistant."
        let changedPrompt = "You are a strict code reviewer."
        
        // Store with original prompt
        await cache.storePrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: originalPrompt,
            tools: nil,
            mode: nil
        )
        
        // Retrieve with changed prompt should return nil
        let retrieved = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: changedPrompt,
            tools: nil,
            mode: nil
        )
        
        XCTAssertNil(retrieved)
    }
    
    // MARK: - Tools Hashing
    
    func testCacheValidatesToolsHash() async throws {
        let conversationId = "test-conv-3"
        let modelId = "test-model-1"
        let systemPrompt = "You are a helpful assistant."
        
        let tools1: [AITool] = [
            FakeTool(name: "read_file", response: ""),
            FakeTool(name: "write_file", response: "")
        ]
        
        let tools2: [AITool] = [
            FakeTool(name: "read_file", response: ""),
            FakeTool(name: "list_files", response: "")  // Different tool
        ]
        
        // Store with tools1
        await cache.storePrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: tools1,
            mode: nil
        )
        
        // Retrieve with tools2 should return nil (different tools)
        let retrieved = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: tools2,
            mode: nil
        )
        
        XCTAssertNil(retrieved)
        
        // Retrieve with same tools should succeed
        let retrievedSame = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: tools1,
            mode: nil
        )
        
        XCTAssertNotNil(retrievedSame)
    }
    
    func testCacheValidatesMode() async throws {
        let conversationId = "test-conv-4"
        let modelId = "test-model-1"
        let systemPrompt = "You are a helpful assistant."
        
        // Store with agent mode
        await cache.storePrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: .agent
        )
        
        // Retrieve with chat mode should return nil
        let retrieved = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: .chat
        )
        
        XCTAssertNil(retrieved)
        
        // Retrieve with same mode should succeed
        let retrievedSame = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: .agent
        )
        
        XCTAssertNotNil(retrievedSame)
    }
    
    // MARK: - Cache Statistics
    
    func testCacheStatistics() async throws {
        let conversationId = "test-conv-5"
        let modelId = "test-model-1"
        let systemPrompt = "You are a helpful assistant."
        
        // Initial stats
        var stats = await cache.getStatistics()
        XCTAssertEqual(stats.totalRequests, 0)
        XCTAssertEqual(stats.cacheHits, 0)
        XCTAssertEqual(stats.cacheMisses, 0)
        
        // Miss
        _ = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        stats = await cache.getStatistics()
        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertEqual(stats.cacheMisses, 1)
        XCTAssertEqual(stats.cacheHits, 0)
        
        // Store
        await cache.storePrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        // Hit
        _ = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        stats = await cache.getStatistics()
        XCTAssertEqual(stats.totalRequests, 2)
        XCTAssertEqual(stats.cacheMisses, 1)
        XCTAssertEqual(stats.cacheHits, 1)
        XCTAssertEqual(stats.hitRate, 0.5, accuracy: 0.01)
    }
    
    func testTokenCountEstimation() async throws {
        let conversationId = "test-conv-6"
        let modelId = "test-model-1"
        let systemPrompt = "You are a helpful coding assistant. Write clean, efficient code."
        
        await cache.storePrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        let retrieved = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        XCTAssertNotNil(retrieved)
        XCTAssertGreaterThan(retrieved!.estimatedTokenCount, 0)
        // Should be roughly word count (10 words)
        XCTAssertGreaterThan(retrieved!.estimatedTokenCount, 5)
    }
    
    // MARK: - Cache Eviction
    
    func testLRUEviction() async throws {
        // Create cache with small capacity
        let smallCache = PromptPrefixCache(maxCachedConversations: 2)
        
        let systemPrompt = "You are a helpful assistant."
        
        // Store 3 entries
        for i in 1...3 {
            await smallCache.storePrefix(
                conversationId: "conv-\(i)",
                modelId: "model-1",
                systemPrompt: systemPrompt,
                tools: nil,
                mode: nil
            )
        }
        
        // First entry should be evicted
        let first = await smallCache.getCachedPrefix(
            conversationId: "conv-1",
            modelId: "model-1",
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        XCTAssertNil(first, "First entry should be evicted")
        
        // Second and third should still exist
        let second = await smallCache.getCachedPrefix(
            conversationId: "conv-2",
            modelId: "model-1",
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        let third = await smallCache.getCachedPrefix(
            conversationId: "conv-3",
            modelId: "model-1",
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
    }
    
    func testInvalidateSpecificConversation() async throws {
        let conversationId = "test-conv-7"
        let modelId = "test-model-1"
        let systemPrompt = "You are a helpful assistant."
        
        await cache.storePrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        await cache.invalidateCache(conversationId: conversationId)
        
        let retrieved = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        XCTAssertNil(retrieved)
    }
    
    func testClearAll() async throws {
        let systemPrompt = "You are a helpful assistant."
        
        // Store multiple entries
        for i in 1...5 {
            await cache.storePrefix(
                conversationId: "conv-\(i)",
                modelId: "model-1",
                systemPrompt: systemPrompt,
                tools: nil,
                mode: nil
            )
        }
        
        await cache.clearAll()
        
        // All should be gone
        for i in 1...5 {
            let retrieved = await cache.getCachedPrefix(
                conversationId: "conv-\(i)",
                modelId: "model-1",
                systemPrompt: systemPrompt,
                tools: nil,
                mode: nil
            )
            XCTAssertNil(retrieved)
        }
    }
    
    // MARK: - Reuse Count
    
    func testReuseCountIncrements() async throws {
        let conversationId = "test-conv-8"
        let modelId = "test-model-1"
        let systemPrompt = "You are a helpful assistant."
        
        await cache.storePrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        // Access multiple times
        for _ in 1...3 {
            _ = await cache.getCachedPrefix(
                conversationId: conversationId,
                modelId: modelId,
                systemPrompt: systemPrompt,
                tools: nil,
                mode: nil
            )
        }
        
        let retrieved = await cache.getCachedPrefix(
            conversationId: conversationId,
            modelId: modelId,
            systemPrompt: systemPrompt,
            tools: nil,
            mode: nil
        )
        
        XCTAssertEqual(retrieved?.reuseCount, 3)
    }
}

// MARK: - Test Helpers

private struct FakeTool: AITool {
    let name: String
    let description: String = "fake"
    var parameters: [String: Any] { ["type": "object", "properties": [:]] }
    let response: String
    
    func execute(arguments: ToolArguments) async throws -> String {
        response
    }
}
