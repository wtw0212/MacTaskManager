# Task Manager for macOS

A native macOS app, written in Swift and SwiftUI, that recreates the Performance tab of the Windows Task Manager.

- **CPU:** a live 60-second graph for every logical core (or one overall graph), utilization, process count, up time, and performance/efficiency core counts.
- **GPU:** a live utilization graph per GPU, plus renderer and tiler graphs on Apple Silicon, GPU memory in use and GPU core count.

## Requirements

macOS 13 or later, and Xcode 15 or later (or the Swift 5.9+ command line tools).

## Run

```sh
swift run -c release
```

Or open `Package.swift` in Xcode and press Run.

## How it reads the numbers

| Data | Apple API |
| --- | --- |
| Per-core CPU ticks | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, diffed once per second |
| GPU utilization and memory | IOKit `IOAccelerator` services, `PerformanceStatistics` dictionary |
| CPU name, core counts | `sysctlbyname` (`machdep.cpu.brand_string`, `hw.perflevel*`) |
| Process count, boot time | `proc_listallpids`, `sysctl(KERN_BOOTTIME)` |

No private frameworks and no root privileges are needed.

## Layout

```
Sources/TaskManager/
  TaskManagerApp.swift        App entry point
  Sampling/                   CPU, GPU and system samplers, PerformanceMonitor (1 s timer, 60 s history)
  Views/                      Sidebar, CPU and GPU detail views, the graph view
```
