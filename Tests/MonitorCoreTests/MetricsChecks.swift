import Foundation
import MonitorCore
import SystemProbe
import Darwin

// No XCTest dependency: also runs with only Apple's Command Line Tools installed.
var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fputs("FAIL: \(description)\n", stderr); exit(1) }
    passed += 1
}
check(MetricMath.rate(current: 106, previous: 100, elapsed: 2, unit: 16384) == 49152, "16 KiB page conversion")
check(MetricMath.rate(current: 100, previous: 100, elapsed: 2, unit: 4096) == 0, "Idle rate is zero")
check(MetricMath.rate(current: 2, previous: 100, elapsed: 2) == nil, "Counter reset")
check(MetricMath.rate(current: 100, previous: 2, elapsed: 0) == nil, "Zero interval")
check(MetricMath.rate(current: 100, previous: 2, elapsed: 31) == nil, "Sleep gap")
check(MetricMath.rate(current: 100, previous: 2, elapsed: .nan) == nil, "Invalid time")
check(MetricMath.processCPU(current: 4_000_000_000, previous: 0, start: 42, previousStart: 42, elapsed: 2) == 200, "Multicore CPU")
check(MetricMath.processCPU(current: 4_000_000_000, previous: 0, start: 43, previousStart: 42, elapsed: 2) == nil, "Reused PID")
let memory = MemoryReading(total: 16, app: 6, wired: 2, compressed: 4)
check(memory.used == 12 && memory.fraction == 0.75, "Memory accounting")
check(MemoryReading(total: 16, app: 20).fraction == 1, "Inconsistent counters are bounded")
check(MemoryReading().fraction == 0, "Missing memory total")
check(DiskReading(total: 100, available: 25).used == 75, "APFS used capacity")
check(DiskReading(total: 0, available: 0).fraction == 0, "Missing disk total")
func tag(_ string: String) -> UInt32 { string.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
var result: Double = 0
check(ql_smc_decode(tag("sp78"), [0x2a, 0x80], 2, &result) && result == 42.5, "Fixed-point temperature")
check(ql_smc_decode(tag("sp78"), [0xff, 0x00], 2, &result) && result == -1, "Signed temperature")
check(!ql_smc_decode(tag("flt "), [0, 0, 0xc0, 0x7f], 4, &result), "Reject NaN sensor")
check(!ql_smc_decode(tag("sp78"), [0], 1, &result), "Reject truncated sensor")
check(!ql_smc_decode(tag("????"), [0, 1], 2, &result), "Reject unknown encoding")
check(ql_smc_decode(tag("flt "), [0, 0, 0x20, 0x41], 4, &result) && result == 10, "Apple Silicon float sensor")

// Compare an actual process CPU counter with getrusage, whose timeval units are
// independent of Mach's timebase. Catches the 125/3 scaling error on Apple Silicon.
func ownCPU() -> UInt64 {
    var processes = [QLProcess](repeating: QLProcess(), count: 8192)
    var total: Int32 = 0
    let count = ql_processes(&processes, Int32(processes.count), &total)
    guard count > 0, let own = processes.prefix(Int(count)).first(where: { $0.pid == getpid() }) else {
        fputs("Cannot read test process CPU counters\n", stderr); exit(1)
    }
    return own.cpu_ns
}
func rusageCPU() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { exit(1) }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
        Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
let before = ownCPU()
let usageBefore = rusageCPU()
let deadline = ProcessInfo.processInfo.systemUptime + 0.25
var checksum: UInt64 = 1
while ProcessInfo.processInfo.systemUptime < deadline {
    for _ in 0..<1000 { checksum = checksum &* 6364136223846793005 &+ 1 }
}
let usageDelta = rusageCPU() - usageBefore
let counterDelta = Double(ownCPU() - before) / 1_000_000_000
check(usageDelta > 0.01 && checksum != 0, "Real CPU work performed")
check((0.7...1.5).contains(counterDelta / usageDelta), "Mach CPU conversion matches getrusage")
print("PASS: \(passed) metric and sensor checks")
