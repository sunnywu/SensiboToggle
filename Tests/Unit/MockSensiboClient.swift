import Foundation
@testable import SensiboToggle

/// Mock implementation of Sensibo client for testing various scenarios.
public final class MockSensiboClient: SensiboClientProtocol {
    
    public struct MockError: Error, LocalizedError {
        public let errorDescription: String?
        
        public init(_ description: String) {
            self.errorDescription = description
        }
    }
    
    private let seed: [AirCon]
    private var currentStates: [String: (on: Bool, temperature: Double?, mode: String?, room: String?)]
    
    public init(seed: [AirCon] = []) {
        self.seed = seed
        // Initialize with mock data for all devices that have a name or room
        self.currentStates = [:]
        
        for ac in seed {
            self.currentStates[ac.id] = (on: ac.on, temperature: ac.temperature, mode: ac.mode, room: ac.room)
        }
    }
    
    public func pods() async throws -> [AirCon] {
        // Simulate network delay for consistency with real API
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        return seed
    }
    
    public func setCurrent(on: Bool, podId: String) async throws {
        // Simulate network error for testing failure scenarios
        if podId == "error" {
            throw MockError("Simulated network error")
        }
        
        // Simulate network delay
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        
        // Update the mock state
        if var currentState = self.currentStates[podId] {
            currentState.on = on
            self.currentStates[podId] = currentState
        }
    }
    
    public func setTemperature(_ temperature: Double?, for podId: String) async throws {
        // Simulate network error for testing failure scenarios
        if podId == "error" {
            throw MockError("Simulated network error")
        }
        
        // Simulate network delay
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        
        // Update the mock state
        if var currentState = self.currentStates[podId] {
            currentState.temperature = temperature
            self.currentStates[podId] = currentState
        }
    }
    
    public func currentStates(ids: [String]) async throws -> [String : (on: Bool, temperature: Double?, mode: String?, room: String?)] {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        return currentStates
    }
    
    public func currentState(podId: String) async throws -> (on: Bool, temperature: Double?, mode: String?, room: String?) {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
        return currentStates[podId] ?? (on: false, temperature: nil, mode: nil, room: nil)
    }
    
    public func warmup() async {
        // Mock warmup - does not actually establish connection
        await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
    }
}