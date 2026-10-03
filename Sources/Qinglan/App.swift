import AppKit
import SwiftUI
import MonitorCore

@main
enum QinglanMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") { diagnose(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func diagnose() {
        let collector = Collector()
        _ = collector.sample(includeProcesses: true)
        Thread.sleep(forTimeInterval: 1)
        let snapshot = collector.sample(includeProcesses: true)
        let output: [String: Any] = [
            "memory": snapshot.memory.map { ["total": $0.total, "used": $0.used, "pressure": $0.pressure] as [String: Any] } ?? [:],
            "paging_bytes_per_second": ["in": snapshot.activity.pageIn ?? -1, "out": snapshot.activity.pageOut ?? -1],
            "disk": snapshot.disk.map { ["total": $0.total, "available": $0.available] } ?? [:],
            "power_watts": snapshot.sensors.watts ?? -1,
            "power_source": snapshot.sensors.powerSource,
            "temperature_celsius": snapshot.sensors.temperature ?? -1,
            "temperature_sensors": snapshot.sensors.sensorCount,
            "processes_readable": snapshot.processes.count,
            "processes_total": snapshot.processTotal,
            "top_memory": snapshot.processes.sorted { $0.resident > $1.resident }.prefix(5).map {
                ["name": $0.name, "resident": $0.resident, "cpu_percent": $0.cpu ?? -1] as [String: Any]
            }
        ]
        if let json = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: json, encoding: .utf8) { print(text) }
        if snapshot.memory == nil || snapshot.disk == nil || snapshot.processes.isEmpty { exit(1) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var panel: MonitorPanel!
    private let monitor = Monitor()
    private var observers: [NSObjectProtocol] = []
    private var previewWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var applicationObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch Services usually handles this; protect command-line launches too.
        if !CommandLine.arguments.contains("--render"),
           let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil); return
        }
        let controller = NSHostingController(rootView: Dashboard(monitor: monitor).background {
            // Window-only captures omit the desktop. This developer fixture makes glass transmission reviewable.
            if CommandLine.arguments.contains("--glass-check") {
                LinearGradient(colors: [Color(red: 0.25, green: 0.63, blue: 0.90), Color(red: 0.75, green: 0.88, blue: 0.84), Color(red: 0.98, green: 0.73, blue: 0.49)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.45)).frame(width: 80) }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        })
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel = MonitorPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: monitor.panelHeight),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "轻览"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Native glass modules own their edges; a window shadow outlines the transparent rectangle.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentViewController = controller
        panel.onDismiss = { [weak self] in self?.hidePanel() }
        if CommandLine.arguments.contains("--dark") { panel.appearance = NSAppearance(named: .darkAqua) }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "轻览")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }
        monitor.onChange = { [weak self] in self?.updateStatus() }
        monitor.onPanelResize = { [weak self] in self?.positionPanel() }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.monitor.pinned else { return }
                self.hidePanel()
            }
        }
        applicationObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.monitor.pinned else { return }
                self.hidePanel()
            }
        })
        applicationObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.positionPanel()
            }
        })
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.monitor.suspend() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.monitor.resume() }
        })
        monitor.start()
        updateStatus()
        if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
            render(to: CommandLine.arguments[index + 1], controller: controller, height: monitor.panelHeight)
        } else if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--show") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.togglePanel() }
        }
    }

    private func updateStatus() {
        let data = monitor.snapshot
        let text: String
        switch monitor.menuMetric {
        case "temperature": text = data.sensors.temperature.map { String(format: " %.0f°", $0) } ?? " —"
        case "power": text = data.sensors.watts.map { String(format: " %.1fW", $0) } ?? " —"
        case "icon": text = ""
        default: text = data.memory.map { String(format: " %.0f%%", $0.fraction * 100) } ?? " —"
        }
        status.button?.title = text
        status.button?.toolTip = "轻览 · 点击查看 Mac 状态"
        status.button?.setAccessibilityLabel("轻览系统监测 \(text)")
    }

    private func positionPanel() {
        guard let button = status.button, let statusWindow = button.window,
              let screen = statusWindow.screen ?? NSScreen.main else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let bounds = screen.visibleFrame
        let desiredHeight = monitor.expandedProcesses ? PanelLayout.expandedHeight : PanelLayout.collapsedHeight
        let height = min(desiredHeight, max(1, bounds.height - 12))
        monitor.panelHeight = height
        let x = min(max(anchor.midX - PanelLayout.width / 2, bounds.minX + 6), bounds.maxX - PanelLayout.width - 6)
        let y = max(bounds.minY + 6, anchor.minY - height - 6)
        panel.setFrame(NSRect(x: x, y: y, width: PanelLayout.width, height: height), display: true)
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel(); return }
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        monitor.setVisible(true)
    }
    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        monitor.setVisible(false)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !panel.isVisible { togglePanel() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        monitor.suspend()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    private func render(to path: String, controller: NSViewController, height: CGFloat) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        if CommandLine.arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        window.contentViewController = controller
        window.center(); window.orderFrontRegardless()
        previewWindow = window
        monitor.setVisible(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let view = controller.view
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
            do { try png.write(to: URL(fileURLWithPath: path)) }
            catch { fputs("Could not write preview: \(error)\n", stderr); exit(2) }
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private final class MonitorPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // AppKit's visual key-appearance hook is separate from actual key-window status.
    // Keep resting glass when clicked without disabling controls or keyboard events.
    @objc(hasKeyAppearance) private func restingKeyAppearance() -> Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func sendEvent(_ event: NSEvent) {
        // Nested hosting views can consume cancelOperation before it reaches the panel.
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onDismiss?()
            return
        }
        super.sendEvent(event)
    }
}
