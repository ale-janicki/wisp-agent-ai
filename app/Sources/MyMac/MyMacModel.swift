import Foundation
import Observation
import WispCore

@MainActor @Observable
final class MyMacModel {
    private(set) var machine: MachineInfo?
    private(set) var snapshot: SystemSnapshot?
    private(set) var cpuHistory = SampleHistory()
    private(set) var memoryHistory = SampleHistory()
    private(set) var downHistory = SampleHistory()
    private(set) var upHistory = SampleHistory()

    @ObservationIgnored private let probe = SystemProbe()

    static let interval: Duration = .seconds(2)
    private static let firstDelta: Duration = .seconds(1)

    func run() async {
        if machine == nil { machine = await probe.machine() }
        var first = true
        while !Task.isCancelled {
            apply(await probe.sample())
            try? await Task.sleep(for: first ? Self.firstDelta : Self.interval)
            first = false
        }
    }

    private func apply(_ sample: SystemSnapshot) {
        snapshot = sample
        if let cpu = sample.cpu { cpuHistory.append(cpu.total) }
        if let memory = sample.memory { memoryHistory.append(memory.usedFraction) }
        if let rate = sample.network?.rate {
            downHistory.append(Double(rate.down))
            upHistory.append(Double(rate.up))
        }
    }
}
