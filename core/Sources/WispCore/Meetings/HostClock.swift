import Darwin

public enum HostClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    public static func seconds(fromHostTime hostTime: UInt64) -> Double {
        Double(hostTime) * secondsPerTick
    }

    public static func nowSeconds() -> Double {
        seconds(fromHostTime: mach_absolute_time())
    }
}
