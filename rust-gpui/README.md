# Task Manager in Rust + GPUI

A second implementation of the Task Manager, in Rust with [GPUI](https://www.gpui.rs) (Zed's
UI framework, `gpui` 0.2.2 from crates.io), to compare against the Swift/SwiftUI app in the
repository root for memory use and CPU overhead.

It has the **Performance** page (per-core CPU grouped by Apple's core types, memory, disks,
networks, GPUs, temperatures) and the **Processes** page (apps with their helper processes,
background processes, sorting, End task), in the same Windows 11 style.

## Same work, different stack

To keep the comparison fair, the Rust app does what the Swift app does:

- Samples every second on the main thread and keeps 60 samples per graph.
- Reads the same Apple APIs (`sampler/`): `host_processor_info`, `host_statistics64`,
  `sysctl`, IOKit (`IOAccelerator`, `IOBlockStorageDriver`, `IODeviceTree:/cpus`, AppleSMC),
  IOHIDEventSystem temperature sensors, `proc_pid_rusage`/`proc_pidinfo`, `NSWorkspace`.
- Samples processes only while the Processes page is open.

Not ported yet: Startup apps, search, per-process network (nettop), the Processes context
menu and properties, update speed, and Fluent icons.

## Run

```sh
cd rust-gpui
cargo run --release                     # Performance page
cargo run --release -- --page processes
```

GPUI compiles its Metal shaders at build time with `xcrun metal`. If that fails (Xcode 26
ships the Metal compiler as a separate download), either run
`xcodebuild -downloadComponent MetalToolchain` or build with `--features runtime-shaders`.

## Compare with the Swift app

```sh
./bench/compare.sh                       # from the repository root
DURATION=120 WARMUP=15 ./bench/compare.sh
```

It builds both apps in release mode, then runs each one alone on each page and samples it every
second with `proc_pid_rusage` (`bench/measure.py`): physical footprint (Activity Monitor's
Memory, which includes GPU surfaces), RSS, CPU time, wakeups, instructions and cycles. The
windows come to the front while they are measured. Results and a Markdown table go to
`bench/results/<timestamp>/`.

The `Rust GPUI` GitHub Actions workflow runs the same comparison on a macOS runner for every
push, with screenshots; the table is on the run's summary page.

### Reading the memory numbers

The footprint counts what each process owns. GPUI renders the whole window itself with Metal,
so its drawables (about 32 MB of IOSurface for a 1100×720 Retina window, triple buffered) are
in the app's footprint. SwiftUI/AppKit hand their layers to the system's render server, so the
equivalent memory sits in WindowServer and does not show in the Swift app's footprint.
`bench/compare.sh` saves each app's `footprint` breakdown by category next to the results.

GPUI also drives each visible window with a display link at the screen's refresh rate, which
shows up as 60–120 wakeups per second even when nothing changes; SwiftUI only wakes for the
1 s timer.

### "GC"

Neither app has a garbage collector. Swift frees memory with automatic reference counting
(retain/release at run time); Rust frees memory at compile-time-determined points (ownership),
with `Rc` only where the UI shares graph histories. The comparison therefore looks at the
footprint over time (steady state and peak) rather than collection pauses.
