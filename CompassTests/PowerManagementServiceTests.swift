//
//  PowerManagementServiceTests.swift
//  CompassTests
//
//  Tests for PowerManagementService
//

import XCTest
@testable import Compass

/// Mock power management service for testing
final class MockPowerManagementService: PowerManagementServiceProtocol, @unchecked Sendable {
    var isActive: Bool = false
    var beginPreventingSleepCallCount = 0
    var stopPreventingSleepCallCount = 0
    
    @discardableResult
    func beginPreventingSleep() -> Bool {
        beginPreventingSleepCallCount += 1
        isActive = true
        return true
    }
    
    func stopPreventingSleep() {
        stopPreventingSleepCallCount += 1
        isActive = false
    }
}

@MainActor
final class PowerManagementServiceTests: XCTestCase {

    // MARK: - Real Service Tests
    
    func testPowerManagementService_StartsInactive() {
        let service = PowerManagementService()
        XCTAssertFalse(service.isActive, "Service should start inactive")
    }
    
    func testPowerManagementService_BeginPreventingSleep_ActivatesService() {
        let service = PowerManagementService()
        
        let result = service.beginPreventingSleep()
        
        XCTAssertTrue(result, "beginPreventingSleep should return true on success")
        XCTAssertTrue(service.isActive, "Service should be active after beginPreventingSleep")
    }
    
    func testPowerManagementService_BeginPreventingSleep_Idempotent() {
        let service = PowerManagementService()
        
        // First call
        _ = service.beginPreventingSleep()
        XCTAssertTrue(service.isActive)
        
        // Second call should be idempotent
        let result = service.beginPreventingSleep()
        XCTAssertTrue(result, "Second call should still return true")
        XCTAssertTrue(service.isActive, "Service should remain active")
    }
    
    func testPowerManagementService_StopPreventingSleep_DeactivatesService() {
        let service = PowerManagementService()
        
        _ = service.beginPreventingSleep()
        XCTAssertTrue(service.isActive)
        
        service.stopPreventingSleep()
        
        XCTAssertFalse(service.isActive, "Service should be inactive after stopPreventingSleep")
    }
    
    func testPowerManagementService_StopPreventingSleep_Idempotent() {
        let service = PowerManagementService()
        
        // Stop without starting
        service.stopPreventingSleep()
        XCTAssertFalse(service.isActive)
        
        // Stop again
        service.stopPreventingSleep()
        XCTAssertFalse(service.isActive, "Service should remain inactive")
    }
    
    func testPowerManagementService_FullCycle() {
        let service = PowerManagementService()
        
        // Start
        XCTAssertTrue(service.beginPreventingSleep())
        XCTAssertTrue(service.isActive)
        
        // Stop
        service.stopPreventingSleep()
        XCTAssertFalse(service.isActive)
        
        // Start again
        XCTAssertTrue(service.beginPreventingSleep())
        XCTAssertTrue(service.isActive)
        
        // Stop again
        service.stopPreventingSleep()
        XCTAssertFalse(service.isActive)
    }
    
    // MARK: - Mock Tests
    
    func testMockPowerManagementService_TracksCalls() {
        let mock = MockPowerManagementService()
        
        XCTAssertEqual(mock.beginPreventingSleepCallCount, 0)
        XCTAssertEqual(mock.stopPreventingSleepCallCount, 0)
        
        _ = mock.beginPreventingSleep()
        XCTAssertEqual(mock.beginPreventingSleepCallCount, 1)
        XCTAssertTrue(mock.isActive)
        
        mock.stopPreventingSleep()
        XCTAssertEqual(mock.stopPreventingSleepCallCount, 1)
        XCTAssertFalse(mock.isActive)
        
        _ = mock.beginPreventingSleep()
        _ = mock.beginPreventingSleep()
        XCTAssertEqual(mock.beginPreventingSleepCallCount, 3)
    }
}