import AppKit
import Combine
import MonitorCore
import ServiceManagement

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published var interval: Double = UserDefaults.standard.object(forKey: "interval") as? Double ?? 2 {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); restartTimer() }
    }
    @Published var menuMetric: String = UserDefaults.standard.string(forKey: "menuMetric") ?? "memory" {
        didSet { UserDefaults.standard.set(menuMetric, forKey: "menuMetric"); onChange?() }
    }
    @Published var pinned = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginMessage: String?
    @Published var visible = false
    @Published var expandedProcesses = false { didSet { onPanelResize?() } }
    @Published var panelHeight = PanelLayout.collapsedHeight
    var onChange: (() -> Void)?
    var onPanelResize: (() -> Void)?
    let chipName: String
    private let collector = Collector()
    private let queue = DispatchQueue(label: "app.qinglan.sampling", qos: .utility)
    private var timer: Timer?
    private var busy = false

    init() {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(size, 1))
        chipName = sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0) == 0 ? String(cString: name) : "Mac"
    }

    func start() { sample(); restartTimer() }
    func setVisible(_ newValue: Bool) {
        visible = newValue
        restartTimer()
        if newValue { sample() }
    }
    func resetAfterWake() {
        queue.async { [collector] in collector.resetIntervals() }
        sample()
    }
    func suspend() { timer?.invalidate(); timer = nil }
    func resume() { resetAfterWake(); restartTimer() }
    private func restartTimer() {
        timer?.invalidate()
        let frequency = visible ? interval : max(5, interval)
        timer = Timer.scheduledTimer(withTimeInterval: frequency, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer?.tolerance = frequency * 0.2
    }
    func sample() {
        guard !busy else { return }
        busy = true
        let processes = visible
        queue.async { [collector, weak self] in
            let sample = collector.sample(includeProcesses: processes)
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = sample
                self.busy = false
                self.onChange?()
                // Opening during an in-flight background sample should populate processes immediately.
                if self.visible && !processes { self.sample() }
            }
        }
    }
    func toggleLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许轻览。" : nil
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = "未能更新登录项：\(error.localizedDescription)"
        }
    }
    func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}
