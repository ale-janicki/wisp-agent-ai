import XCTest
@testable import WispCore

final class SystemFormatTests: XCTestCase {
    func testBytesDecimalAndBinary() {
        XCTAssertEqual(SystemFormat.bytes(0), "0 B")
        XCTAssertEqual(SystemFormat.bytes(950), "950 B")
        XCTAssertEqual(SystemFormat.bytes(12_340_000), "12,3 MB")
        XCTAssertEqual(SystemFormat.bytes(139_929_477_120), "140 GB")
        XCTAssertEqual(SystemFormat.bytes(494_384_795_648), "494 GB")
        XCTAssertEqual(SystemFormat.bytes(2_000_000_000), "2 GB")
        XCTAssertEqual(SystemFormat.bytes(17_179_869_184, binary: true), "16 GB")
        XCTAssertEqual(SystemFormat.bytes(11_268_915_200, binary: true), "10,5 GB")
        XCTAssertEqual(SystemFormat.bytes(999_960_000), "1 GB", "rounding carries into the next unit")
    }

    func testRatePercentCelsius() {
        XCTAssertEqual(SystemFormat.rate(1_234_567), "1,2 MB/s")
        XCTAssertEqual(SystemFormat.percent(0.374), "37%")
        XCTAssertEqual(SystemFormat.percent(1.7), "100%")
        XCTAssertEqual(SystemFormat.percent(.nan), "0%")
        XCTAssertEqual(SystemFormat.celsius(51.6), "52 °C")
        XCTAssertEqual(SystemFormat.processCPU(97.84), "97,8%")
        XCTAssertEqual(SystemFormat.processCPU(0), "0%")
        XCTAssertEqual(SystemFormat.processCPU(312.4), "312%")
    }

    func testDurationAndLoad() {
        XCTAssertEqual(SystemFormat.duration(45), "45 s")
        XCTAssertEqual(SystemFormat.duration(12 * 60 + 5), "12 min")
        XCTAssertEqual(SystemFormat.duration(3 * 3600 + 5 * 60), "3 h 05 min")
        XCTAssertEqual(SystemFormat.duration(6 * 86_400 + 3 * 3600 + 6 * 60), "6 d 3 h")
        XCTAssertEqual(SystemFormat.duration(-5), "0 s")
        XCTAssertEqual(SystemFormat.load([15.51, 10.8, 2]), "15,51 · 10,80 · 2,00")
    }
}

final class CPUUsageTests: XCTestCase {
    func testTotalAndClusters() throws {
        let before = [
            CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
            CPUTicks(user: 0, system: 0, idle: 1000, nice: 0),
            CPUTicks(user: 500, system: 0, idle: 500, nice: 0),
        ]
        let after = [
            CPUTicks(user: 150, system: 75, idle: 875, nice: 0),
            CPUTicks(user: 10, system: 0, idle: 1090, nice: 0),
            CPUTicks(user: 580, system: 10, idle: 510, nice: 0),
        ]
        let usage = try XCTUnwrap(CPUUsage.between(before, after, kinds: [.efficiency, .efficiency, .performance]))
        XCTAssertEqual(usage.total, 175.0 / 300, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(usage.efficiency), 85.0 / 200, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(usage.performance), 0.9, accuracy: 1e-9)
    }

    func testCounterWrapAndNoClusters() throws {
        let before = [CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 9, nice: 0)]
        let after = [CPUTicks(user: 10, system: 0, idle: 30, nice: 0)]
        let usage = try XCTUnwrap(CPUUsage.between(before, after))
        XCTAssertEqual(usage.total, 20.0 / 60, accuracy: 1e-9)
        XCTAssertNil(usage.efficiency)
        XCTAssertNil(usage.performance)
    }

    func testMismatchOrNoTicksIsNil() {
        let one = [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)]
        XCTAssertNil(CPUUsage.between(one, one + one))
        XCTAssertNil(CPUUsage.between(one, one))
        XCTAssertNil(CPUUsage.between([], []))
    }
}

final class MemoryBreakdownTests: XCTestCase {
    func testActivityMonitorSplit() {
        let counts = VMPageCounts(pageSize: 16_384, free: 1000, active: 300_000, inactive: 290_000, speculative: 2000,
                                  wired: 150_000, compressor: 200_000, purgeable: 5000, external: 120_000, internalPages: 400_000)
        let memory = MemoryBreakdown(counts: counts, total: 17_179_869_184)
        XCTAssertEqual(memory.app, 395_000 * 16_384)
        XCTAssertEqual(memory.wired, 150_000 * 16_384)
        XCTAssertEqual(memory.compressed, 200_000 * 16_384)
        XCTAssertEqual(memory.cached, 125_000 * 16_384)
        XCTAssertEqual(memory.used, 745_000 * 16_384)
        XCTAssertEqual(memory.usedFraction, Double(745_000 * 16_384) / 17_179_869_184, accuracy: 1e-12)
    }

    func testPurgeableAboveInternalDoesNotUnderflow() {
        let counts = VMPageCounts(pageSize: 4096, free: 0, active: 0, inactive: 0, speculative: 0,
                                  wired: 0, compressor: 0, purgeable: 10, external: 0, internalPages: 5)
        XCTAssertEqual(MemoryBreakdown(counts: counts, total: 0).app, 0)
        XCTAssertEqual(MemoryBreakdown(counts: counts, total: 0).usedFraction, 0)
    }

    func testPressureLevels() {
        XCTAssertEqual(MemoryPressure(level: 1), .normal)
        XCTAssertEqual(MemoryPressure(level: 2)?.label, "Alerta")
        XCTAssertEqual(MemoryPressure(level: 4), .critical)
        XCTAssertNil(MemoryPressure(level: 3))
    }
}

final class NetworkRateTests: XCTestCase {
    func testRateAndWrap() throws {
        let rate = try XCTUnwrap(NetworkRate.between(
            InterfaceCounters(received: 1000, sent: 500),
            InterfaceCounters(received: 5000, sent: 1500),
            seconds: 2
        ))
        XCTAssertEqual(rate, NetworkRate(down: 2000, up: 500))
        let wrapped = try XCTUnwrap(NetworkRate.between(
            InterfaceCounters(received: UInt32.max - 999, sent: 0),
            InterfaceCounters(received: 1000, sent: 0),
            seconds: 1
        ))
        XCTAssertEqual(wrapped.down, 2000)
        XCTAssertNil(NetworkRate.between(InterfaceCounters(received: 0, sent: 0), InterfaceCounters(received: 1, sent: 1), seconds: 0))
    }
}

final class ProcessTableTests: XCTestCase {
    private let output = """
      PID  %CPU    RSS COMM
      101  91.1  10688 Python
      202   7.5 258848 Browser Helper (Aperitif Renderer)
      303   6,8 524240 claude
      404   0.0   1200 ps
      505   0.0 900000 WindowServer
    garbage line
      606   abc    100 broken

    """

    func testParsesNamesWithSpacesAndCommaDecimals() {
        let rows = ProcessTable.parse(output)
        XCTAssertEqual(rows.map(\.pid), [101, 202, 303, 505])
        XCTAssertEqual(rows[1].name, "Browser Helper (Aperitif Renderer)")
        XCTAssertEqual(rows[2].cpu, 6.8, accuracy: 1e-9)
        XCTAssertEqual(rows[2].residentBytes, 524_240 * 1024)
    }

    func testTopFive() {
        let rows = ProcessTable.parse(output)
        XCTAssertEqual(ProcessTable.topByCPU(rows, count: 2).map(\.name), ["Python", "Browser Helper (Aperitif Renderer)"])
        XCTAssertEqual(ProcessTable.topByMemory(rows).map(\.pid), [505, 303, 202, 101])
        XCTAssertTrue(ProcessTable.parse("").isEmpty)
    }
}

final class TemperatureSummaryTests: XCTestCase {
    func testGroupsSensorsAndDropsImplausible() throws {
        let summary = TemperatureSummary(readings: [
            SensorReading(name: "PMU tdie1", celsius: 60),
            SensorReading(name: "PMU2 tdie5", celsius: 50),
            SensorReading(name: "PMU tdev1", celsius: -22),
            SensorReading(name: "PMU tdev3", celsius: 43),
            SensorReading(name: "NAND CH0 temp", celsius: 50),
            SensorReading(name: "gas gauge battery", celsius: 37),
            SensorReading(name: "gas gauge battery", celsius: 38),
            SensorReading(name: "PMU tdie9", celsius: 400),
        ])
        XCTAssertEqual(try XCTUnwrap(summary.socAverage), 55, accuracy: 1e-9)
        XCTAssertEqual(summary.socMax, 60)
        XCTAssertEqual(summary.ssd, 50)
        XCTAssertEqual(try XCTUnwrap(summary.battery), 37.5, accuracy: 1e-9)
        XCTAssertFalse(summary.isEmpty)
    }

    func testNoSensorsIsEmpty() {
        XCTAssertTrue(TemperatureSummary(readings: []).isEmpty)
        XCTAssertTrue(TemperatureSummary(readings: [SensorReading(name: "als-temp", celsius: 0)]).isEmpty)
        XCTAssertEqual(ThermalLevel(rawValue: 2)?.label, "Sério")
    }
}

final class BatteryStatusTests: XCTestCase {
    func testDischarging() throws {
        let status = try XCTUnwrap(BatteryStatus.from(
            powerSource: ["Current Capacity": 94, "Max Capacity": 100, "Is Charging": false,
                          "Power Source State": "Battery Power", "Time to Empty": 231, "Time to Full Charge": -1],
            registry: ["CycleCount": 152, "BatteryData": ["DesignCapacity": 4629, "NominalChargeCapacity": 4591]]
        ))
        XCTAssertEqual(status.percent, 94)
        XCTAssertEqual(status.state, .discharging)
        XCTAssertEqual(status.cycleCount, 152)
        XCTAssertEqual(status.health, 99)
        XCTAssertEqual(status.timeLabel, "3 h 51 min restantes")
        XCTAssertEqual(status.stateLabel, "Na bateria")
    }

    func testChargingChargedAndEstimating() throws {
        let charging = try XCTUnwrap(BatteryStatus.from(
            powerSource: ["Current Capacity": 50, "Max Capacity": 100, "Is Charging": true,
                          "Power Source State": "AC Power", "Time to Full Charge": 65],
            registry: [:]
        ))
        XCTAssertEqual(charging.state, .charging)
        XCTAssertEqual(charging.timeLabel, "1 h 05 min para carregar")
        XCTAssertNil(charging.health)
        let charged = try XCTUnwrap(BatteryStatus.from(
            powerSource: ["Current Capacity": 100, "Max Capacity": 100, "Is Charged": true, "Power Source State": "AC Power"],
            registry: ["DesignCapacity": 4000, "NominalChargeCapacity": 3800]
        ))
        XCTAssertEqual(charged.state, .charged)
        XCTAssertNil(charged.timeLabel)
        XCTAssertEqual(charged.health, 95)
        let estimating = try XCTUnwrap(BatteryStatus.from(
            powerSource: ["Current Capacity": 80, "Max Capacity": 100, "Power Source State": "Battery Power", "Time to Empty": -1],
            registry: [:]
        ))
        XCTAssertNil(estimating.timeLabel)
        XCTAssertNil(BatteryStatus.from(powerSource: ["Current Capacity": 80], registry: [:]))
    }
}

final class SampleHistoryTests: XCTestCase {
    func testCapsAndNormalizes() {
        var history = SampleHistory(capacity: 3)
        for value in [1.0, 2, 3, 4, .nan] { history.append(value) }
        XCTAssertEqual(history.values, [3, 4, 0])
        XCTAssertEqual(history.normalized(), [0.75, 1, 0])
        XCTAssertEqual(history.normalized(floor: 8), [0.375, 0.5, 0])
        XCTAssertEqual(SampleHistory().normalized(), [])
        var zeros = SampleHistory()
        zeros.append(0)
        XCTAssertEqual(zeros.normalized(), [0])
    }
}

final class MachineInfoTests: XCTestCase {
    func testDeviceTreeStringAndBuild() {
        XCTAssertEqual(MachineInfo.deviceTreeString(Data("MacBook Air (13-inch, M4, 2025)\0".utf8)), "MacBook Air (13-inch, M4, 2025)")
        XCTAssertNil(MachineInfo.deviceTreeString(Data([0])))
        XCTAssertEqual(MachineInfo.build(fromVersionString: "Version 27.0.1 (Build 26A434)"), "26A434")
        XCTAssertNil(MachineInfo.build(fromVersionString: "Version 27.0.1"))
        XCTAssertEqual(MachineInfo.version(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)), "27.0.1")
        XCTAssertEqual(MachineInfo.version(OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0)), "15.2")
    }

    func testVolumesOrderedBootFirst() {
        let volumes = VolumeUsage.ordered([
            VolumeUsage(name: "Backup", path: "/Volumes/Backup", total: 100, available: 25, availableRaw: 20, isBoot: false),
            VolumeUsage(name: "Macintosh HD", path: "/", total: 100, available: 30, availableRaw: 10, isBoot: true),
            VolumeUsage(name: "Backup", path: "/Volumes/Backup", total: 100, available: 25, availableRaw: 20, isBoot: false),
        ])
        XCTAssertEqual(volumes.map(\.path), ["/", "/Volumes/Backup"])
        XCTAssertEqual(volumes[0].usedFraction, 0.7, accuracy: 1e-9)
    }
}
