//
//  ExternalAPITestIsolation.swift
//  CompassTests
//
//  Utility for ensuring external API tests run serially to prevent rate limiting
//

import Foundation
import XCTest
@testable import Compass

/// Ensures that tests using external APIs run serially to prevent rate limiting
/// and request flooding issues
public actor ExternalAPITestIsolation {
    public static let shared = ExternalAPITestIsolation()
    
    private var isRunning = false
    private var waitQueue: [CheckedContinuation<Void, Never>] = []
    
    private init() {}
    
    /// Acquire exclusive access for external API testing
    /// Tests will wait serially if another test is already using external APIs
    public func acquireExternalAPIAccess() async {
        if !isRunning {
            isRunning = true
            return
        }
        
        await withCheckedContinuation { continuation in
            waitQueue.append(continuation)
        }
    }
    
    /// Release exclusive access for external API testing
    /// Allows the next waiting test to proceed
    public func releaseExternalAPIAccess() {
        if let next = waitQueue.first {
            waitQueue.removeFirst()
            next.resume()
        } else {
            isRunning = false
        }
    }
    
    /// Run a test block with exclusive external API access
    /// Automatically handles acquisition and release
    public func withExternalAPIAccess<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async rethrows -> T {
        await acquireExternalAPIAccess()
        defer { Task { await releaseExternalAPIAccess() } }
        
        return try await operation()
    }
}

/// Mixin for XCTestCase classes that need external API access
public protocol ExternalAPITestMixin: XCTestCase {
    /// Override this method to configure test-specific settings
    func configureExternalAPITest() -> TestConfiguration
    
    /// Call this method in your test setup to ensure isolation
    func setupExternalAPITest() async
}

public extension ExternalAPITestMixin {
    func configureExternalAPITest() -> TestConfiguration {
        return .default
    }
    
    func setupExternalAPITest() async {
        let config = configureExternalAPITest()
        await TestConfigurationProvider.shared.setConfiguration(config)
        
        if config.serialExternalAPITests {
            await ExternalAPITestIsolation.shared.acquireExternalAPIAccess()
        }
    }
    
    func teardownExternalAPITest() async {
        let config = await TestConfigurationProvider.shared.configuration
        if config.serialExternalAPITests {
            await ExternalAPITestIsolation.shared.releaseExternalAPIAccess()
        }
        
        await TestConfigurationProvider.shared.resetToDefault()
    }
}

/// Utility class for running external API tests with proper isolation
public final class ExternalAPITestRunner {
    private let isolation = ExternalAPITestIsolation.shared
    
    /// Run a test block with exclusive external API access
    public func runTest<T: Sendable>(
        testCase: XCTestCase,
        configuration: TestConfiguration = .default,
        operation: @Sendable @escaping () async throws -> T
    ) async rethrows -> T {
        // Set up test configuration
        await TestConfigurationProvider.shared.setConfiguration(configuration)
        
        // Run with isolation if required
        if configuration.serialExternalAPITests {
            return try await isolation.withExternalAPIAccess(operation)
        } else {
            return try await operation()
        }
    }
}
