import Foundation

public enum UsageFormat {
    private static let scales: [(size: Double, unit: String)] = [(1e9, "bi"), (1e6, "mi"), (1e3, "mil")]

    public static func tokens(_ count: Int) -> String {
        let value = Double(max(0, count))
        guard var index = scales.firstIndex(where: { value >= $0.size }) else { return String(Int(value)) }
        var tenths = (value / scales[index].size * 10).rounded() / 10
        if tenths >= 1000, index > 0 {
            index -= 1
            tenths = (value / scales[index].size * 10).rounded() / 10
        }
        var text = String(format: "%.1f", tenths).replacingOccurrences(of: ".", with: ",")
        if text.hasSuffix(",0") { text.removeLast(2) }
        return "\(text) \(scales[index].unit)"
    }
}
