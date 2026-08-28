import Foundation

/// A single air conditioner / air handler controllable through Sensibo.
struct AirCon: Hashable, Identifiable, Equatable {
    let id: String
    var name: String = ""
    var room: String?
    var on: Bool = false
    var temperature: Double?
    var mode: String?

    /// Get the temperature as a string for display purposes.
    var temperatureDisplay: String {
        if let temp = self.temperature {
            return "\(Int(temp))°"
        }
        return "-"
    }
}

extension AirCon {
    var displayName: String {
        if let room, !room.isEmpty { return room }
        if !name.isEmpty { return name }
        return "AC \(id.suffix(4))"
    }

    var symbol: String { on ? "flame.fill" : "snowflake" }
}

/// The current control state of one air conditioner.
enum ControlState: Equatable {
    case idle(AirCon)
    case pending(AirCon)
    case error(AirCon, String)
}

// MARK: - Light (Tapo)

/// A single controllable light (a Tapo bulb today). Mirrors `AirCon` so the UI and
/// controller can treat both device families the same way.
struct Light: Hashable, Identifiable, Equatable {
    let id: String
    var name: String = ""
    var room: String?
    var on: Bool = false

     /// Human label for the row: fall back to room, then name, then a short id.
    var displayName: String {
        if let room, !room.isEmpty { return room }
        if !name.isEmpty { return name }
        return "Light \(id.suffix(4))"
        }

     /// The SF Symbol shown for this light, filled when on.
    var symbol: String { on ? "lightbulb.fill" : "lightbulb" }
}

/// One configured Tapo device. The local IP is required for direct KLAP control.
struct TapoDeviceConfig: Equatable, Sendable {
    var name: String
    var ip: String
    var type: String?
}
