import Foundation

public struct MemoryReading: Sendable {
    public var total: Double = 0
    public var app: Double = 0
    public var wired: Double = 0
    public var compressed: Double = 0
    public var cached: Double = 0
    public var swap: Double = 0
    public var pressure: Int = 0
    public var used: Double { min(total, max(0, app + wired + compressed)) }
    public var fraction: Double { total > 0 ? used / total : 0 }
    public var pressureText: String {
        switch pressure { case 1: return "压力正常"; case 2: return "压力偏高"; case 4: return "压力较大"; default: return "压力未知" }
    }
    public init(total: Double = 0, app: Double = 0, wired: Double = 0, compressed: Double = 0) {
        self.total = total; self.app = app; self.wired = wired; self.compressed = compressed
    }
}

public struct ActivityReading: Sendable {
    public var pageIn: Double?
    public var pageOut: Double?
    public var swapIn: Double?
    public var swapOut: Double?
    public init() {}
}

public struct DiskReading: Sendable {
    public var total: Double
    public var available: Double
    public var used: Double { max(0, total - available) }
    public var fraction: Double { total > 0 ? min(1, used / total) : 0 }
    public init(total: Double, available: Double) { self.total = total; self.available = available }
}

public struct SensorReading: Sendable {
    public var watts: Double?
    public var powerSource: String = "系统功耗"
    public var powerDetail: String = "此机型暂未提供可读取的功耗传感器。"
    public var temperature: Double?
    public var temperatureDetail: String = "此机型暂未提供可读取的芯片温度。"
    public var sensorCount: Int = 0
    public init() {}
}

public struct ProcessReading: Identifiable, Sendable {
    public let pid: Int32
    public let startTime: UInt64
    public let name: String
    public let resident: Double
    public let cpu: Double?
    public var id: String { "\(pid)-\(startTime)" }
    public init(pid: Int32, startTime: UInt64, name: String, resident: Double, cpu: Double?) {
        self.pid = pid; self.startTime = startTime; self.name = name; self.resident = resident; self.cpu = cpu
    }
}

public struct Snapshot: Sendable {
    public var date = Date()
    public var memory: MemoryReading?
    public var activity = ActivityReading()
    public var disk: DiskReading?
    public var sensors = SensorReading()
    public var processes: [ProcessReading] = []
    public var processTotal = 0
    public var processError = false
    public init() {}
}

public enum MetricMath {
    // Counter reset, first sample and sleep gaps must not produce a fake spike.
    public static func rate(current: UInt64, previous: UInt64, elapsed: Double, unit: Double = 1) -> Double? {
        guard elapsed > 0, elapsed <= 30, elapsed.isFinite, current >= previous else { return nil }
        return Double(current - previous) * unit / elapsed
    }
    public static func processCPU(current: UInt64, previous: UInt64, start: UInt64, previousStart: UInt64, elapsed: Double) -> Double? {
        guard start == previousStart else { return nil }
        return rate(current: current, previous: previous, elapsed: elapsed, unit: 1e-7)
    }
}

public enum MetricFormat {
    public static func memory(_ bytes: Double) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", bytes / 1_073_741_824) }
        return String(format: "%.0f MB", bytes / 1_048_576)
    }
    public static func disk(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000_000 { return String(format: "%.2f TB", bytes / 1_000_000_000_000) }
        return String(format: "%.0f GB", bytes / 1_000_000_000)
    }
    public static func rate(_ bytes: Double?) -> String {
        guard let bytes else { return "—" }
        if bytes >= 1_048_576 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB/s", bytes / 1024) }
        return String(format: "%.0f B/s", bytes)
    }
}
