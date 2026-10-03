import SwiftUI
import MonitorCore

private enum Palette {
    // Opaque text colors avoid the low-contrast vibrancy of hierarchical secondary styles.
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.98, green: 0.98, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.06, green: 0.08, blue: 0.11, alpha: 1)
    })
    static let detail = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.88, green: 0.90, blue: 0.93, alpha: 1)
            : NSColor(srgbRed: 0.22, green: 0.25, blue: 0.29, alpha: 1)
    })
    static let mint = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.30, green: 0.78, blue: 0.61, alpha: 1)
        }
        return NSColor(srgbRed: 0.04, green: 0.56, blue: 0.40, alpha: 1)
    })
    static let blue = Color(red: 0.32, green: 0.52, blue: 0.84)
    static let lilac = Color(red: 0.59, green: 0.48, blue: 0.80)
}

@MainActor
private final class DashboardState: ObservableObject {
    @Published var settings = false
    @Published var sortByCPU = false
    @Published var onlyBackground = false
    @Published var showInfo = false
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @StateObject private var ui = DashboardState()
    private var data: Snapshot { monitor.snapshot }

    var body: some View {
        VStack(spacing: PanelLayout.gap) {
            if ui.settings {
                ScrollView(showsIndicators: false) {
                    SettingsView(monitor: monitor)
                        .quietGlassCard()
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: PanelLayout.gap) {
                        memoryCard
                        HStack(alignment: .top, spacing: PanelLayout.gap) { activityCard; diskCard }
                        HStack(spacing: PanelLayout.gap) { powerCard; temperatureCard }
                        processesCard
                    }
                }
            }
            footer
        }
        .padding(.horizontal, PanelLayout.outerInset)
        .padding(.vertical, PanelLayout.gap)
        .frame(width: PanelLayout.width, height: monitor.panelHeight)
        .foregroundStyle(Palette.ink)
        .tint(Palette.mint)
        .popover(isPresented: $ui.showInfo, arrowEdge: .bottom) { information }
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                title("内存占用", icon: "memorychip")
                Spacer()
                if let memory = data.memory {
                    Text(memory.pressureText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(pressureColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(pressureColor.opacity(0.12), in: Capsule())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(data.memory.map { String(format: "%.0f", $0.fraction * 100) } ?? "—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-0.6).monospacedDigit()
                Text("%").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.detail)
                Spacer()
                if let memory = data.memory {
                    Text("\(MetricFormat.memory(memory.used)) / \(MetricFormat.memory(memory.total))")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Palette.detail)
                }
            }
            HStack(spacing: 0) {
                memoryLegend("应用", bytes: data.memory?.app, color: Palette.mint)
                Spacer(minLength: 4)
                memoryLegend("联动", bytes: data.memory?.wired, color: Palette.blue)
                Spacer(minLength: 4)
                memoryLegend("压缩", bytes: data.memory?.compressed, color: Palette.lilac)
            }
        }
        .padding(.horizontal, PanelLayout.cardInset).padding(.vertical, PanelLayout.cardVerticalInset).quietGlassCard()
        .help("已用内存 = 应用 + 联动 + 压缩。内存压力由系统报告，不仅取决于占用百分比。")
    }

    private func memoryLegend(_ label: String, bytes: Double?, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(label).foregroundStyle(Palette.detail)
            Text(bytes.map(MetricFormat.memory) ?? "—").monospacedDigit()
        }.font(.system(size: 10, weight: .medium))
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                title("内存速率", icon: "arrow.up.arrow.down")
                Spacer(minLength: 2)
                Text("页入").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.detail)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "arrow.down").foregroundStyle(Palette.mint).font(.system(size: 11, weight: .semibold))
                Text(MetricFormat.rate(data.activity.pageIn)).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 5) {
                Text("页出 ↑").foregroundStyle(Palette.detail)
                Text(MetricFormat.rate(data.activity.pageOut)).monospacedDigit()
            }.font(.system(size: 10))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, PanelLayout.cardInset).padding(.vertical, PanelLayout.cardVerticalInset).quietGlassCard()
            .help("主数值为页入速率，含文件分页。磁盘交换：换入 \(MetricFormat.rate(data.activity.swapIn))，换出 \(MetricFormat.rate(data.activity.swapOut))。这不是内存硬件带宽。")
    }

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                title("硬盘占用", icon: "internaldrive")
                Spacer(minLength: 2)
                Text(data.disk.map { "\(Int($0.fraction * 100))%" } ?? "—").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.detail)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(data.disk.map { MetricFormat.disk($0.used) } ?? "—").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 5) {
                Text("可用").foregroundStyle(Palette.detail)
                Text(data.disk.map { MetricFormat.disk($0.available) } ?? "—").monospacedDigit()
            }.font(.system(size: 10))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, PanelLayout.cardInset).padding(.vertical, PanelLayout.cardVerticalInset).quietGlassCard()
            .overlay(alignment: .bottomLeading) {
                GeometryReader { proxy in
                    Capsule().fill(Palette.blue.opacity(0.6)).frame(width: max(0, proxy.size.width - PanelLayout.cardInset * 2) * (data.disk?.fraction ?? 0), height: 2).offset(x: PanelLayout.cardInset, y: proxy.size.height - 7)
                }.allowsHitTesting(false)
            }
            .help("启动磁盘 APFS 数据卷。总容量 \(data.disk.map { MetricFormat.disk($0.total) } ?? "—")；可用空间不含可清除缓存，每 30 秒更新。")
    }

    private var powerCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            title(data.sensors.powerSource, icon: "bolt")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(data.sensors.watts.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
                Text(data.sensors.watts == nil ? "暂不可用" : "W").font(.system(size: 11)).foregroundStyle(Palette.detail)
                Spacer()
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, PanelLayout.cardInset).padding(.vertical, PanelLayout.cardVerticalInset).quietGlassCard().help(data.sensors.powerDetail)
    }

    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            title("芯片温度", icon: "thermometer.medium")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(data.sensors.temperature.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
                Text(data.sensors.temperature == nil ? "暂不可用" : "°C").font(.system(size: 11)).foregroundStyle(Palette.detail)
                Spacer()
                Text("峰值").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.detail)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, PanelLayout.cardInset).padding(.vertical, PanelLayout.cardVerticalInset).quietGlassCard().help(data.sensors.temperatureDetail)
    }

    private var rankedProcesses: [ProcessReading] {
        let apps = ui.onlyBackground ? Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)) : []
        return data.processes.filter { !apps.contains($0.pid) }.sorted {
            if ui.sortByCPU {
                if ($0.cpu ?? -1) != ($1.cpu ?? -1) { return ($0.cpu ?? -1) > ($1.cpu ?? -1) }
            }
            if $0.resident != $1.resident { return $0.resident > $1.resident }
            return $0.pid < $1.pid
        }
    }

    private var processesCard: some View {
        VStack(spacing: 5) {
            HStack {
                title("进程排行", icon: "list.number")
                Menu {
                    Button("全部进程") { ui.onlyBackground = false }
                    Button("仅后台进程") { ui.onlyBackground = true }
                } label: {
                    HStack(spacing: 2) { Text(ui.onlyBackground ? "后台" : "全部"); Image(systemName: "chevron.down").font(.system(size: 7)) }
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.detail)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("后台筛选会排除有常规应用界面的主进程，保留辅助进程。")
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    sortButton("内存", selected: !ui.sortByCPU) { ui.sortByCPU = false }
                    sortButton("CPU", selected: ui.sortByCPU) { ui.sortByCPU = true }
                }.padding(2).background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 6) {
                Text("名称")
                Spacer()
                Text("CPU").frame(width: 43, alignment: .trailing)
                Text("内存").frame(width: 51, alignment: .trailing)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.detail)
            VStack(spacing: 5) {
                ForEach(Array(rankedProcesses.prefix(monitor.expandedProcesses ? 5 : 3).enumerated()), id: \.element.id) { index, process in
                    HStack(spacing: 6) {
                        Text(String(index + 1)).font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Palette.detail).frame(width: 10)
                        Text(process.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(process.cpu.map { String(format: "%.1f%%", $0) } ?? "—")
                            .foregroundStyle(Palette.ink)
                            .frame(width: 43, alignment: .trailing)
                        Text(MetricFormat.memory(process.resident))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 51, alignment: .trailing)
                    }.font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                        .help("\(process.name) · PID \(process.pid)\n内存为驻留大小；CPU 100% 对应占满一个逻辑核心。")
                }
                if data.processes.isEmpty {
                    Text(data.processError ? "暂时无法读取进程" : "正在采样进程…")
                        .font(.system(size: 11)).foregroundStyle(Palette.detail).frame(height: monitor.expandedProcesses ? 80 : 48)
                }
            }
            HStack {
                Text("可读取 \(data.processes.count) / \(data.processTotal)").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.detail)
                Spacer()
                Button { monitor.expandedProcesses.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(monitor.expandedProcesses ? "收起至前三名" : "展开至前五名")
                        Image(systemName: monitor.expandedProcesses ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .medium))
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink)
                }.buttonStyle(.plain)
                    .accessibilityLabel(monitor.expandedProcesses ? "收起至前三名" : "展开至前五名")
                Button { monitor.openActivityMonitor() } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11)).foregroundStyle(Palette.detail)
                }.buttonStyle(.plain).help("打开活动监视器").accessibilityLabel("打开活动监视器")
            }
        }.padding(.horizontal, PanelLayout.cardInset).padding(.vertical, PanelLayout.cardVerticalInset).quietGlassCard()
    }

    private func sortButton(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(selected ? Palette.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(selected ? 0.25 : 0), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { ui.settings.toggle() } label: {
                Image(systemName: ui.settings ? "checkmark" : "gearshape")
                    .font(.system(size: 12, weight: .medium)).frame(width: 22, height: 24)
            }.help(ui.settings ? "完成设置" : "设置").accessibilityLabel(ui.settings ? "完成设置" : "设置")
            Button { ui.showInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 24)
            }.help("指标说明").accessibilityLabel("指标说明")
            Button { monitor.pinned.toggle() } label: {
                Image(systemName: monitor.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(monitor.pinned ? Palette.mint : Palette.ink)
                    .frame(width: 22, height: 24)
            }.help(monitor.pinned ? "取消固定面板" : "保持面板展开").accessibilityLabel("固定面板")
            Spacer(minLength: 4)
            Text("每 \(Int(monitor.interval)) 秒更新").font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.detail)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 24)
            }.help("退出轻览").accessibilityLabel("退出轻览")
        }.buttonStyle(.plain).foregroundStyle(Palette.ink)
            .padding(.horizontal, PanelLayout.cardInset).padding(.vertical, 8).quietGlassCard()
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每一个数字，都有出处").font(.system(size: 15, weight: .semibold))
            Text("内存：应用、联动及压缩之和；GB 按 1024³ 字节显示。压力来自系统。\n\n速率：相邻采样的分页计数差，页入包含文件读取；磁盘交换单独显示在下方。\n\n硬盘：启动磁盘数据卷，GB 按 1000³ 字节显示，每 30 秒更新。\n\n进程：可读取进程的驻留内存；CPU 100% 为一个逻辑核心。受保护进程可能不可读。\n\n\(data.sensors.powerDetail)\n\n\(data.sensors.temperatureDetail)")
                .font(.system(size: 11)).foregroundStyle(Palette.detail).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("交换已用  \(data.memory.map { MetricFormat.memory($0.swap) } ?? "—")\n换入  \(MetricFormat.rate(data.activity.swapIn))    换出  \(MetricFormat.rate(data.activity.swapOut))")
                .font(.system(size: 11, design: .monospaced))
            Text("所有数据仅在本机处理。收起后每 5 秒采样，并暂停进程排行采样。")
                .font(.system(size: 10)).foregroundStyle(Palette.detail)
        }.padding(18).frame(width: 300)
    }

    private var pressureColor: Color {
        switch data.memory?.pressure { case 1: return Palette.mint; case 2: return .orange; case 4: return .red; default: return Palette.detail }
    }
    private func title(_ label: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Palette.detail).frame(width: 12)
            Text(label).font(.system(size: 11, weight: .semibold))
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("按你的习惯，安静运行。").font(.system(size: 16, weight: .medium))
            VStack(alignment: .leading, spacing: 10) {
                Text("采样间隔").font(.system(size: 12, weight: .medium))
                Picker("采样间隔", selection: $monitor.interval) {
                    Text("1 秒").tag(1.0); Text("2 秒").tag(2.0); Text("5 秒").tag(5.0)
                }.pickerStyle(.segmented).labelsHidden()
                Text("收起面板后自动降至每 5 秒，暂停进程采样；睡眠时停止采样。")
                    .font(.system(size: 10)).foregroundStyle(Palette.detail)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("菜单栏显示").font(.system(size: 12, weight: .medium))
                Picker("菜单栏显示", selection: $monitor.menuMetric) {
                    Text("内存").tag("memory"); Text("温度").tag("temperature"); Text("功耗").tag("power"); Text("仅图标").tag("icon")
                }.pickerStyle(.segmented).labelsHidden()
            }
            Divider()
            Toggle("登录后自动启动", isOn: Binding(get: { monitor.loginEnabled }, set: { monitor.toggleLogin($0) }))
                .toggleStyle(.switch).font(.system(size: 12))
            if let message = monitor.loginMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("建议先将轻览移到“应用程序”文件夹，再开启自动启动。")
                .font(.system(size: 10)).foregroundStyle(Palette.detail)
            VStack(alignment: .leading, spacing: 7) {
                Text("轻览  1.0.7").font(.system(size: 12, weight: .medium))
                Text("原生 macOS 应用 · 无网络请求 · 无第三方依赖").font(.system(size: 10)).foregroundStyle(Palette.detail)
            }
        }.padding(16)
    }
}
