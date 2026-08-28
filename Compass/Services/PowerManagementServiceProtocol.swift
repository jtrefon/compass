//
//  PowerManagementServiceProtocol.swift
//  Compass
//
//  Protocol for power management service - allows mocking in tests
//

import Foundation

/// Protocol for power management service - allows mocking in tests
/// Thread-safe - implementations should handle synchronization internally
protocol PowerManagementServiceProtocol: AnyObject, Sendable {
    /// Whether a power assertion is currently active
    var isActive: Bool { get }
    
    /// Begin preventing system sleep
    /// - Returns: true if assertion was successfully created
    @discardableResult
    func beginPreventingSleep() -> Bool
    
    /// Stop preventing system sleep
    func stopPreventingSleep()
}
