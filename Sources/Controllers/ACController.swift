import Foundation
import SwiftUI

/// Controller that manages the UI state and coordinates with the Sensibo API Client.
public final class ACController: ObservableObject {
    
    @Published public var acs: [AirCon] = []
    @Published public var isLoading = false
    @Published public var error: String?
    
    private let client: SensiboClientProtocol
    
    // MARK: - Initialization
    
    public init(client: SensiboClientProtocol) {
        self.client = client
    }
    
    // MARK: - Public Methods
    
    /// Loads all AC units from the API.
    public func load() async {
        await MainActor.run {
            isLoading = true
            error = nil
        }
        
        do {
            let pods = try await client.pods()
            
            await MainActor.run {
                self.acs = pods
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    /// Toggles the on/off state of an AC unit.
    public func toggle(_ podId: String) async {
        // Optimistic update - immediately flip UI state
        await MainActor.run {
            if let index = acs.firstIndex(where: { $0.id == podId }) {
                var updatedAC = acs[index]
                updatedAC.on.toggle()
                acs[index] = updatedAC
            }
        }
        
        // Perform actual API call
        do {
            try await client.setCurrent(on: !acs.first(where: { $0.id == podId })!.on, podId: podId)
            
            // Confirm the operation succeeded by reloading from server
            // This is where we would typically update the UI to reflect that it's confirmed
            await load()
        } catch {
            // In case of error, revert UI change and show error
            await MainActor.run {
                if let index = acs.firstIndex(where: { $0.id == podId }) {
                    var updatedAC = acs[index]
                    updatedAC.on.toggle()  // Revert the change
                    acs[index] = updatedAC
                }
                self.error = "Failed to toggle device: \(error.localizedDescription)"
            }
        }
    }
    
    /// Sets the temperature for an AC unit.
    public func setTemperature(_ temperature: Double?, for podId: String) async {
        // Optimistic update - immediately show the change in UI
        await MainActor.run {
            if let index = acs.firstIndex(where: { $0.id == podId }) {
                var updatedAC = acs[index]
                updatedAC.temperature = temperature
                acs[index] = updatedAC
            }
        }
        
        // Perform actual API call
        do {
            try await client.setTemperature(temperature, for: podId)
            
            // Confirm the operation succeeded by reloading from server
            await load()
        } catch {
            // In case of error, revert UI change and show error
            await MainActor.run {
                self.error = "Failed to set temperature: \(error.localizedDescription)"
            }
        }
    }
    
    /// Pre-warms the connection for better perceived latency.
    public func warmup() async {
        await client.warmup()
    }
}