import Foundation
import SystemProbe

/// The lock protects all sampler state; the application calls this on its utility queue.
public final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var previousMemory: (QLMemory, TimeInterval)?
    private var previousProcesses: [Int32: (start: UInt64, cpu: UInt64)] = [:]
    private var previousProcessTime: TimeInterval?
    private var disk: DiskReading?
    private var diskTime: TimeInterval = -.infinity
    private let sensors = SensorReader()

    public init() {}

    public func resetIntervals() {
        lock.lock(); defer { lock.unlock() }
        previousMemory = nil
        previousProcesses.removeAll(keepingCapacity: true)
        previousProcessTime = nil
    }

    public func sample(includeProcesses: Bool) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        var result = Snapshot()
        var raw = QLMemory()
        if ql_memory(&raw) {
            var memory = MemoryReading(total: Double(raw.total), app: Double(raw.app), wired: Double(raw.wired), compressed: Double(raw.compressed))
            memory.cached = Double(raw.cached); memory.swap = Double(raw.swap); memory.pressure = Int(raw.pressure)
            result.memory = memory
            if let (old, time) = previousMemory {
                let elapsed = now - time
                let page = Double(raw.page_size)
                result.activity.pageIn = MetricMath.rate(current: raw.pageins, previous: old.pageins, elapsed: elapsed, unit: page)
                result.activity.pageOut = MetricMath.rate(current: raw.pageouts, previous: old.pageouts, elapsed: elapsed, unit: page)
                result.activity.swapIn = MetricMath.rate(current: raw.swapins, previous: old.swapins, elapsed: elapsed, unit: page)
                result.activity.swapOut = MetricMath.rate(current: raw.swapouts, previous: old.swapouts, elapsed: elapsed, unit: page)
            }
            previousMemory = (raw, now)
        } else { previousMemory = nil }
        if now - diskTime >= 30 {
            let url = URL(fileURLWithPath: "/System/Volumes/Data")
            if let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
               let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity {
                disk = DiskReading(total: Double(total), available: Double(free))
            } else { disk = nil }
            diskTime = now
        }
        result.disk = disk
        result.sensors = sensors.read()
        if includeProcesses {
            var rawProcesses = [QLProcess](repeating: QLProcess(), count: 8192)
            var total: Int32 = 0
            let count = ql_processes(&rawProcesses, Int32(rawProcesses.count), &total)
            result.processTotal = Int(total)
            result.processError = count < 0
            var next: [Int32: (start: UInt64, cpu: UInt64)] = [:]
            if count >= 0 {
                result.processes = rawProcesses.prefix(Int(count)).map { process in
                    var nameBytes = process.name
                    let name = withUnsafePointer(to: &nameBytes) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
                    }
                    var cpu: Double?
                    if let old = previousProcesses[process.pid], let time = previousProcessTime {
                        cpu = MetricMath.processCPU(current: process.cpu_ns, previous: old.cpu,
                            start: process.start_us, previousStart: old.start, elapsed: now - time)
                    }
                    next[process.pid] = (process.start_us, process.cpu_ns)
                    return ProcessReading(pid: process.pid, startTime: process.start_us, name: name,
                                          resident: Double(process.resident), cpu: cpu)
                }
            }
            previousProcesses = next
            previousProcessTime = now
        } else {
            previousProcesses.removeAll(keepingCapacity: true)
            previousProcessTime = nil
        }
        return result
    }
}

private final class SensorReader {
    private var smc: OpaquePointer?
    private var temperatureKeys: [String] = []
    private var lastDiscovery: TimeInterval = -.infinity

    deinit { ql_smc_close(smc) }

    private func value(_ key: String) -> Double? {
        var result: Double = 0
        return ql_smc_read(smc, key, &result) ? result : nil
    }

    private func discover() {
        lastDiscovery = ProcessInfo.processInfo.systemUptime
        if smc == nil { smc = ql_smc_open() }
        guard smc != nil else { return }
        var buffer = [CChar](repeating: 0, count: 512 * 5)
        let count = ql_smc_keys(smc, &buffer, 512)
        var keys: [String] = []
        for index in 0..<Int(count) {
            let key = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress! + index * 5) }
            #if arch(arm64)
            // These are chip thermal zones, not a one-to-one map to physical cores.
            let isChip = ["Tp", "Te", "Tf", "Tg"].contains { key.hasPrefix($0) }
            #else
            let isChip = key.hasPrefix("TC") || key.hasPrefix("TG")
            #endif
            if isChip, let temp = value(key), (10...125).contains(temp) { keys.append(key) }
        }
        temperatureKeys = keys
    }

    func read() -> SensorReading {
        if ProcessInfo.processInfo.systemUptime - lastDiscovery > 300 { discover() }
        var result = SensorReading()
        let temperatures = temperatureKeys.compactMap { key -> Double? in
            guard let temperature = value(key), (10...125).contains(temperature) else { return nil }
            return temperature
        }
        result.temperature = temperatures.max()
        result.sensorCount = temperatures.count
        if !temperatures.isEmpty {
            result.temperatureDetail = "CPU / GPU 芯片热区中最高的有效温度，来自 \(temperatures.count) 个 SMC 传感器。热区不等同于物理核心。"
        }
        if let watts = value("PSTR"), watts > 0, watts < 1500 {
            result.watts = watts
            result.powerDetail = "SMC 系统总功率（PSTR），单位 W。反映硬件传感器读数，不等同于插座功率。"
        } else if let watts = value("PCPC"), watts > 0, watts < 1000 {
            result.watts = watts
            result.powerSource = "CPU 功耗"
            result.powerDetail = "此机型提供 CPU 封装功率（PCPC），不包含整机的全部耗电。"
        } else {
            var watts: Double = 0
            if ql_battery_discharge(&watts) {
                result.watts = watts
                result.powerSource = "电池放电"
                result.powerDetail = "电池电压 × 放电电流，仅在使用电池时可用；不代表 CPU 单独功耗。"
            }
        }
        if temperatures.isEmpty && result.watts == nil {
            // Re-open after transient sleep/wake failures, throttled to avoid constant discovery.
            if ProcessInfo.processInfo.systemUptime - lastDiscovery > 30 {
                ql_smc_close(smc); smc = nil; discover()
            }
        }
        return result
    }
}
