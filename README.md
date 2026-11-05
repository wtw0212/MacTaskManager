# Task Manager for macOS

A native macOS app, written in Swift and SwiftUI, modelled on the Windows Task Manager.

- **Processes:** every process with CPU, memory and thread count, filters for apps and background processes, search, End task and Force quit.
- **Performance:**
  - **CPU:** a live 60-second graph per logical core, grouped by core type using Apple's own names (for example Performance and Efficiency), utilization per group, temperature, thermal state, process count and up time.
  - **Memory:** usage graph, composition bar, app/wired/compressed/cached memory, swap and memory pressure.
  - **Disk:** per physical disk, active time and read/write speed graphs, capacity and startup volume free space.
  - **Network:** per Wi-Fi/Ethernet interface, send/receive graph, IPv4/IPv6 address and totals.
  - **GPU:** utilization graph, renderer and tiler graphs on Apple Silicon, GPU memory in use, temperature and core count.
- **Startup apps:** launchd agents and daemons that start automatically, with Enable/Disable.

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
| Core types and names | `hw.perflevelN.name` / `logicalcpu`, IODeviceTree `cpus/*/cluster-type` |
| Process count, boot time | `proc_listallpids`, `sysctl(KERN_BOOTTIME)` |
| Per-process CPU and memory | `proc_pid_rusage(RUSAGE_INFO_V4)`, `proc_pidinfo`, `NSWorkspace` |
| Memory | `host_statistics64(HOST_VM_INFO64)`, `vm.swapusage` |
| Disk | IOKit `IOBlockStorageDriver` `Statistics` |
| Network | `sysctl(NET_RT_IFLIST2)` 64-bit counters, SystemConfiguration names, `getifaddrs` |
| Temperatures | IOKit `IOHIDEventSystemClient` temperature sensors, `ProcessInfo.thermalState` |
| Startup apps | `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, `launchctl` |

No root privileges are needed. Apple has no public temperature API, so temperatures use IOHIDEventSystem functions that IOKit exports but doesn't declare in its headers. That is fine for direct distribution, but not for the Mac App Store.

## Build a DMG

```sh
./scripts/make-dmg.sh
```

This makes a universal, ad-hoc signed `dist/TaskManager.dmg`.

## Layout

```
Sources/TaskManager/
  TaskManagerApp.swift        App entry point
  Sampling/                   CPU, GPU and system samplers, PerformanceMonitor (1 s timer, 60 s history)
  Views/                      Sidebar, CPU and GPU detail views, the graph view
```

## Icons

UI icons are [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons) by Microsoft, MIT License (see `LICENSES/FluentUI-System-Icons.txt`). `scripts/generate-fluent-icons.py` turns their SVGs into SwiftUI shapes in `Views/FluentIcons.swift`; to add one, add it to `ICONS` in the script and rerun it on the `@fluentui/svg-icons` package.
