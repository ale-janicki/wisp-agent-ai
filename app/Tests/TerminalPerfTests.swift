import AppKit
import Darwin
import WispCore
import XCTest

@testable import Wisp

@MainActor
final class TerminalPerfTests: TerminalPaneCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WISP_PERF"] == "1", "set WISP_PERF=1 to run the performance test")
        try await super.setUp()
    }

    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private func megabytes(_ bytes: Int) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

    private struct Sample {
        var name: String
        var seconds: Double
        var before: Int
        var after: Int
        var lines: Int
        var dropped: Int
        var stages: TerminalPerf.Counters
        var cpu: Double
    }

    private var samples = [Sample]()

    private func measure(_ name: String, _ command: String, count: Int) throws {
        let before = Self.residentBytes()
        TerminalPerf.reset()
        let cpuBefore = Self.cpuSeconds()
        let start = Date()
        XCTAssertTrue(session.submit(command))
        let done = pump(240) { self.blocks.count == count && self.blocks.last?.isRunning == false && self.blocks.last?.output != nil }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertTrue(done, "\(name) did not finish in 240 s")
        let after = Self.residentBytes()
        let output = try XCTUnwrap(blocks.last?.output)
        samples.append(Sample(name: name, seconds: seconds, before: before, after: after, lines: output.lines.count, dropped: output.droppedLines, stages: TerminalPerf.counters, cpu: Self.cpuSeconds() - cpuBefore))
    }

    func testFloodsOfOutput() throws {
        waitForPrompt()
        let big = try scratchFile("big.txt")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/bin/sh")
        make.arguments = ["-c", "yes 'the quick brown fox jumps over the lazy dog 0123456789 abcdefghij' | head -c 52428800 > '\(big)'"]
        try make.run()
        make.waitUntilExit()
        XCTAssertEqual(make.terminationStatus, 0)
        let size = (try FileManager.default.attributesOfItem(atPath: big)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 50_000_000)

        run("echo warm", expecting: 1)
        let baseline = Self.residentBytes()
        try measure("seq 1 1000000", "seq 1 1000000", count: 2)
        try measure("yes | head -n 300000", "yes | head -n 300000", count: 3)
        try measure("cat 50 MB file", "cat '\(big)'", count: 4)
        pumpFor(1)
        let settled = Self.residentBytes()

        var report = ["WISP_PERF (resident MB, mach_task_basic_info; wall seconds from submit to the block's output being frozen)"]
        for sample in samples {
            report.append(
                "\(sample.name): \(String(format: "%.2f", sample.seconds)) s wall (\(String(format: "%.2f", sample.cpu)) s cpu), resident \(megabytes(sample.before)) -> \(megabytes(sample.after)) MB (+\(megabytes(sample.after - sample.before))), kept \(sample.lines) lines, dropped \(sample.dropped)")
            let stages = sample.stages
            func ms(_ ns: UInt64) -> Int { Int(ns / 1_000_000) }
            report.append(
                "    stages (ms): read thread \(ms(stages.readNs)) in \(stages.reads) reads, of it end/prompt captures \(ms(stages.captureNs)) in \(stages.captures); main-thread ticks \(ms(stages.tickNs)) in \(stages.ticks), of it live capture \(ms(stages.liveNs)) in \(stages.liveTicks)")
        }
        report.append("process baseline \(megabytes(baseline)) MB, after all three \(megabytes(settled)) MB (+\(megabytes(settled - baseline)))")
        let text = report.joined(separator: "\n")
        print(text)
        try? text.write(toFile: (NSTemporaryDirectory() as NSString).appendingPathComponent("wisp-perf.txt"), atomically: true, encoding: .utf8)

        XCTAssertTrue((1_000_000...1_000_001).contains(samples[0].lines + samples[0].dropped), "\(samples[0].lines) + \(samples[0].dropped)")
        XCTAssertEqual(blocks[1].output?.lines.last?.text, "1e+06")
        XCTAssertLessThan(megabytes(settled - baseline), 300, "more than 300 MB of growth")
    }
}
