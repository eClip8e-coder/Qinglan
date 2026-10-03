# 数据口径与实现说明

## 功能与数据口径

| 指标 | 显示内容 | 数据来源 |
| --- | --- | --- |
| 内存占用 | 使用比例、应用 / 联动 / 压缩内存、系统压力 | Mach `host_statistics64`、`sysctl` |
| 内存速率 | 页入 / 页出速率；说明面板显示 swap 换入 / 换出与交换已用量 | 相邻 VM 计数差 × 本机页大小 ÷ 实际采样间隔 |
| 硬盘占用 | 启动盘已用、可用、占用比例 | APFS 数据卷容量接口 |
| 进程排行 | 默认前 3 名，可展开到前 5 名；CPU / 内存排序，全部 / 后台筛选 | `libproc`，Mach 时钟换算 |
| 功耗 | 系统总功率（W） | SMC `PSTR`，有标签区分的 CPU / 电池放电回退 |
| 温度 | CPU / GPU 芯片热区的当前最高温度（°C） | 只读 SMC 温度传感器 |

- 内存速率按需求采用**实时分页活动**，不是硬件频率或 DRAM 带宽。首次采样、唤醒或计数重置时显示 `—`，不伪造零值或峰值。
- 内存采用 1024 进制显示 GB / MB；硬盘采用 1000 进制，与厂商容量口径一致。硬盘“可用”不包含尚未清除的可回收缓存，可能与系统设置略有不同。
- 内存占用率高不必然等于内存压力高；压力标记直接使用系统状态。
- 进程内存为驻留内存 RSS，与活动监视器的物理内存占用口径可能不同。CPU 100% 对应一个逻辑核心，因此多线程进程可以超过 100%。
- 后台筛选排除有常规应用界面的主进程，保留应用辅助进程与可读取的服务。受系统保护的进程可能不可读，界面显示读取数量 / 总数量。
- 温度显示**当前芯片热区峰值**，不是历史最高温或整机平均温度。传感器热区不等同于物理核心。
- 功耗主来源是 SMC 系统总功率，不等同于插座功率。不同 Mac 的传感器支持可能不同，无法读取时明确显示“暂不可用”。没有 SMC 写入、风扇调节或特权后台服务。

## 原生玻璃与兼容性

界面使用 SwiftUI + AppKit。macOS 26 及更新版本使用 `NSGlassEffectView`，内容放在其 `contentView` 中；旧版本回退到超薄磨砂，开启“降低透明度”时使用实色背景。

macOS 27 上，在系统版本、选择器和公开材质映射检查通过时，使用内部玻璃变体 `_variant = 9`。面板通过内部 `hasKeyAppearance` 外观钩子维持柔和的静止外观，关闭玻璃交互效果，同时保留按钮和键盘焦点。点击面板不会切换整块材质，界面仍随系统深浅色与背后内容变化。

**玻璃变体、外观钩子和 SMC 传感器包含非公开接口。** 系统更新可能影响它们，不保证所有 Mac 的显示和传感器结果一致；此版本不适合直接提交 App Store。玻璃变体检查不通过时回退到公开原生玻璃；传感器读取失败时显示暂不可用。

## 布局与采样

面板默认 320 × 452 点，展开前五名后为 320 × 490 点。卡片和底栏使用固定 20 点圆角，模块间完全透明。没有历史曲线或其数据缓存，只保留计算速率所需的上次采样值。

默认每 2 秒采样，可选 1 / 2 / 5 秒。面板收起后每 5 秒更新，并暂停进程枚举；磁盘每 30 秒读取一次。睡眠时停止计时器，唤醒后重置速率基线。没有网络请求、第三方运行时、特权后台服务或用于轮询数据的 shell 子进程。

应用自身的 CPU、内存与耗电随设备、进程数量和面板状态变化；这里不对续航损耗作未经测量的承诺。

## 开发检查

```sh
bash scripts/test.sh
./dist/轻览.app/Contents/MacOS/Qinglan --diagnose
open dist/轻览.app --args --show
./dist/轻览.app/Contents/MacOS/Qinglan --render "$PWD/artifacts/preview-layout.png"
bash scripts/make-icon.sh
```

测试使用独立可执行程序，不依赖 XCTest，覆盖页面大小、计数重置、睡眠间隔、PID 复用、多核 CPU、内存与磁盘口径、SMC 编码及异常数据，并将本机 CPU 计时与 `getrusage` 对照。

`--render` 用于离屏布局检查，不能完整导出窗口合成器产生的玻璃。请直接打开面板检查真实材质；`--glass-check` 临时绘制测试色带，`--dark` 临时检查深色模式。预览读取真实数据，不使用演示数据。

## 接口参考

- [Apple：AppKit 原生玻璃与内容层关系](https://developer.apple.com/videos/play/wwdc2025/310/)
- [Qt Liquid Glass：内部变体研究](https://github.com/fsalinas26/qt-liquid-glass)（仅参考接口研究，未引入依赖；旧编号不能直接用于 macOS 27）
- [Apple：虚拟内存统计](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/VMPages.html)
- [Apple XNU：进程 CPU 计时实现](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)
- [Stats：AppleSMC 协议参考](https://github.com/exelban/stats/blob/master/SMC/smc.swift)
- [Stats：传感器键参考](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)

SMC 接口与传感器键并非 Apple 稳定公开 API。应用将其隔离在只读采集层，并在读取失败时保留其他监测功能。
