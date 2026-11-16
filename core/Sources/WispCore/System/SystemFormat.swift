import Foundation

public enum SystemFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func bytes(_ count: UInt64, binary: Bool = false) -> String {
        let base: Double = binary ? 1024 : 1000
        var value = Double(count)
        var index = 0
        while value >= base, index < units.count - 1 {
            value /= base
            index += 1
        }
        if index == 0 { return "\(count) B" }
        if (value * 10).rounded() / 10 >= base, index < units.count - 1 {
            value /= base
            index += 1
        }
        return "\(decimal(value, digits: value < 100 ? 1 : 0)) \(units[index])"
    }

    public static func rate(_ bytesPerSecond: UInt64) -> String {
        "\(bytes(bytesPerSecond))/s"
    }

    public static func percent(_ fraction: Double) -> String {
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        return "\(Int((clamped * 100).rounded()))%"
    }

    public static func processCPU(_ percent: Double) -> String {
        let value = max(0, percent.isFinite ? percent : 0)
        return "\(decimal(value, digits: value < 100 ? 1 : 0))%"
    }

    public static func celsius(_ value: Double) -> String {
        "\(Int(value.rounded())) °C"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return String(format: "%d h %02d min", hours, minutes) }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    public static func load(_ averages: [Double]) -> String {
        averages.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") }.joined(separator: " · ")
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
        if digits > 0, text.hasSuffix("," + String(repeating: "0", count: digits)) {
            text.removeLast(digits + 1)
        }
        return text
    }
}
