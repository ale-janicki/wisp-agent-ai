import Foundation

public struct BatteryStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable { case charging, charged, onAC, discharging }

    public var percent: Int
    public var state: State
    public var cycleCount: Int?
    public var designCapacity: Int?
    public var nominalCapacity: Int?
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?

    public init(percent: Int, state: State, cycleCount: Int? = nil, designCapacity: Int? = nil,
                nominalCapacity: Int? = nil, minutesToEmpty: Int? = nil, minutesToFull: Int? = nil) {
        self.percent = percent
        self.state = state
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.nominalCapacity = nominalCapacity
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
    }

    public var health: Int? {
        guard let designCapacity, let nominalCapacity, designCapacity > 0 else { return nil }
        return Int((Double(nominalCapacity) / Double(designCapacity) * 100).rounded())
    }

    public var stateLabel: String {
        switch state {
        case .charging: "Carregando"
        case .charged: "Carregada"
        case .onAC: "Na tomada"
        case .discharging: "Na bateria"
        }
    }

    public var timeLabel: String? {
        switch state {
        case .discharging:
            minutesToEmpty.map { "\(SystemFormat.duration(TimeInterval($0 * 60))) restantes" }
        case .charging:
            minutesToFull.map { "\(SystemFormat.duration(TimeInterval($0 * 60))) para carregar" }
        case .charged, .onAC:
            nil
        }
    }

    public static func from(powerSource: [String: Any], registry: [String: Any]) -> BatteryStatus? {
        guard let current = powerSource["Current Capacity"] as? Int,
              let max = powerSource["Max Capacity"] as? Int, max > 0
        else { return nil }
        let charging = powerSource["Is Charging"] as? Bool ?? false
        let onAC = (powerSource["Power Source State"] as? String) == "AC Power"
        let charged = powerSource["Is Charged"] as? Bool ?? false
        let state: State = charging ? .charging : (onAC ? (charged ? .charged : .onAC) : .discharging)
        let battery = registry["BatteryData"] as? [String: Any]
        func minutes(_ key: String) -> Int? {
            guard let value = powerSource[key] as? Int, value >= 0 else { return nil }
            return value
        }
        return BatteryStatus(
            percent: Int((Double(current) / Double(max) * 100).rounded()),
            state: state,
            cycleCount: registry["CycleCount"] as? Int,
            designCapacity: (registry["DesignCapacity"] as? Int) ?? (battery?["DesignCapacity"] as? Int),
            nominalCapacity: (registry["NominalChargeCapacity"] as? Int) ?? (battery?["NominalChargeCapacity"] as? Int),
            minutesToEmpty: minutes("Time to Empty"),
            minutesToFull: minutes("Time to Full Charge")
        )
    }
}
