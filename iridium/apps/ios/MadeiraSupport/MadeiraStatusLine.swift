import Foundation

/// One line of device state for the runtime log, written every few seconds
/// while a game runs. It exists to tell apart "iOS slowed the phone down"
/// (thermal state, Low Power Mode) from "the game was waiting on something"
/// when the whole game freezes for seconds.
enum MadeiraStatusLine {
    static let interval: TimeInterval = 5

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func megabytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "n/a" }
        return "\(bytes / 1_048_576)MB"
    }

    static func format(thermal: String, lowPower: Bool, usedBytes: UInt64?, availableBytes: UInt64?,
                       seconds: Double) -> String {
        "[Status] +\(String(format: "%.0f", seconds))s thermal=\(thermal) lowPower=\(lowPower ? "on" : "off") "
            + "footprint=\(megabytes(usedBytes)) available=\(megabytes(availableBytes))"
    }
}
