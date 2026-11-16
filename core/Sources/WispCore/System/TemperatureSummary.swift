import Foundation

public struct SensorReading: Equatable, Sendable {
    public var name: String
    public var celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public struct TemperatureSummary: Equatable, Sendable {
    public var socAverage: Double?
    public var socMax: Double?
    public var ssd: Double?
    public var battery: Double?

    public var isEmpty: Bool { socAverage == nil && ssd == nil && battery == nil }

    public init(socAverage: Double? = nil, socMax: Double? = nil, ssd: Double? = nil, battery: Double? = nil) {
        self.socAverage = socAverage
        self.socMax = socMax
        self.ssd = ssd
        self.battery = battery
    }

    static let plausible: ClosedRange<Double> = 1...130

    public init(readings: [SensorReading]) {
        let valid = readings.filter { Self.plausible.contains($0.celsius) }
        let die = valid.filter { $0.name.hasPrefix("PMU") && $0.name.contains("tdie") }.map(\.celsius)
        let ssd = valid.filter { $0.name.hasPrefix("NAND") }.map(\.celsius)
        let battery = valid.filter { $0.name.lowercased().contains("battery") }.map(\.celsius)
        self.init(socAverage: Self.mean(die), socMax: die.max(), ssd: Self.mean(ssd), battery: Self.mean(battery))
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

public enum ThermalLevel: Int, Sendable {
    case nominal, fair, serious, critical

    public var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Moderado"
        case .serious: "Sério"
        case .critical: "Crítico"
        }
    }
}
