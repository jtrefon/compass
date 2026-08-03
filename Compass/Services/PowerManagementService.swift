//
//  PowerManagementService.swift
//  Compass
//
//  Service to prevent system sleep during critical operations
//  Uses macOS IOKit power assertions to prevent sleep while agent is active
//

import Foundation
import IOKit.pwr_mgt

/// Service to prevent system sleep during critical operations
/// This prevents the agent from failing due to macOS power saving features
/// Thread-safe via NSLock - can be accessed from any actor/queue.
final class PowerManagementService: PowerManagementServiceProtocol, @unchecked Sendable {
    
    // MARK: - Properties
    
    /// Whether a power assertion is currently active
    private(set) var isActive: Bool = false
    
    /// The current power assertion ID
    private var assertionID: IOPMAssertionID = 0
    
    /// Name used for the assertion in system logs and Activity Monitor
    private let assertionName = "com.Compass.agent-active" as CFString
    
    /// Reason shown in Activity Monitor Energy tab
    private let assertionReason = "AI Agent is actively processing" as CFString
    
    /// Lock for thread safety
    private let lock = NSLock()
    
    // MARK: - Lifecycle
    
    deinit {
        // Ensure assertion is released when service is deallocated
        lock.lock()
        defer { lock.unlock() }
        
        if isActive {
            IOPMAssertionRelease(assertionID)
        }
    }
    
    // MARK: - Public Methods
    
    /// Begin preventing system sleep
    /// Uses kIOPMAssertPreventUserIdleSystemSleep which prevents system sleep
    /// but allows the display to dim for power efficiency
    /// - Returns: true if assertion was successfully created
    @discardableResult
    func beginPreventingSleep() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isActive else {
            // Already active, no need to create another assertion
            return true
        }
        
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            assertionName,
            &assertionID
        )
        
        if result == kIOReturnSuccess {
            isActive = true
            logAssertionStarted()
            return true
        } else {
            logAssertionFailed(error: result)
            return false
        }
    }
    
    /// Stop preventing system sleep
    /// Releases the power assertion, allowing normal sleep behavior to resume
    func stopPreventingSleep() {
        lock.lock()
        defer { lock.unlock() }
        
        guard isActive else {
            // Not active, nothing to release
            return
        }
        
        let result = IOPMAssertionRelease(assertionID)
        
        if result == kIOReturnSuccess {
            logAssertionReleased()
        } else {
            logReleaseFailed(error: result)
        }
        
        isActive = false
        assertionID = 0
    }
    
    // MARK: - Private Methods
    
    private func logAssertionStarted() {
    }
    
    private func logAssertionReleased() {
    }
    
    private func logAssertionFailed(error: IOReturn) {
    }
    
    private func logReleaseFailed(error: IOReturn) {
    }
}
