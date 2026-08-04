//
//  TestConfiguration.swift
//  Compass
//
//  Configuration for test execution to control external API usage and isolation
//

import Foundation

/// Configuration for test execution that controls external API access
public struct TestConfiguration: Sendable {
    /// Whether to allow external API calls during testing
    public let allowExternalAPIs: Bool
    
    /// Minimum interval between external API requests (rate limiting)
    public let minAPIRequestInterval: TimeInterval
    
    /// Whether to run external API tests serially (prevents flooding)
    public let serialExternalAPITests: Bool
    
    /// Timeout for external API requests during testing
    public let externalAPITimeout: TimeInterval
    
    /// Whether to use mock services instead of real ones
    public let useMockServices: Bool
    
    public static let `default` = TestConfiguration(
        allowExternalAPIs: true,
        minAPIRequestInterval: 1.0, // 1 second between requests
        serialExternalAPITests: true,
        externalAPITimeout: 60.0, // 60 seconds
        useMockServices: false
    )
    
    public static let isolated = TestConfiguration(
        allowExternalAPIs: false,
        minAPIRequestInterval: 2.0, // 2 seconds between requests
        serialExternalAPITests: true,
        externalAPITimeout: 30.0, // 30 seconds
        useMockServices: true
    )
    
    public static let ci = TestConfiguration(
        allowExternalAPIs: true,
        minAPIRequestInterval: 2.0, // Conservative for CI
        serialExternalAPITests: true,
        externalAPITimeout: 120.0, // Longer timeout for CI
        useMockServices: false
    )
    
    /// Load configuration from environment variables
    public static func fromEnvironment() -> TestConfiguration {
        let allowExternalAPIs = ProcessInfo.processInfo.environment["ALLOW_EXTERNAL_APIS"] != "false"
        let serialExternalAPITests = ProcessInfo.processInfo.environment["SERIAL_EXTERNAL_API_TESTS"] != "false"
        let useMockServices = ProcessInfo.processInfo.environment["USE_MOCK_SERVICES"] == "true"
        
        let minInterval = Double(ProcessInfo.processInfo.environment["MIN_API_REQUEST_INTERVAL"] ?? "") ?? 1.0
        let timeout = Double(ProcessInfo.processInfo.environment["EXTERNAL_API_TIMEOUT"] ?? "") ?? 60.0
        
        return TestConfiguration(
            allowExternalAPIs: allowExternalAPIs,
            minAPIRequestInterval: minInterval,
            serialExternalAPITests: serialExternalAPITests,
            externalAPITimeout: timeout,
            useMockServices: useMockServices
        )
    }
}

/// Global test configuration provider
public actor TestConfigurationProvider {
    public static let shared = TestConfigurationProvider()
    
    private var currentConfiguration: TestConfiguration = .fromEnvironment()
    
    public init() {}
    
    public var configuration: TestConfiguration {
        get { currentConfiguration }
        set { currentConfiguration = newValue }
    }
    
    public func setConfiguration(_ config: TestConfiguration) {
        currentConfiguration = config
    }
    
    public func resetToDefault() {
        currentConfiguration = .fromEnvironment()
    }
}
