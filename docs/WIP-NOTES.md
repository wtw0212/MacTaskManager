# WIP notes: five new features

Base: main at cc27d9f. This branch builds with zero warnings (`swift build`).

## Rules for this work
- Use only Design.swift tokens/components; add new ones there. Numbers never wrap. Fluent icons only, via
  scripts/generate-fluent-icons.py (`npm pack @fluentui/svg-icons`, `pip install svgelements`).
- No SwiftUI Canvas: it costs tens of MB of GPU surfaces. Use the shape-layer `UsageGraph`.
- RAM target: about 30 MB on Performance, about 64 MB on Processes. Measure footprint after each feature and
  don't regress by more than a few MB. Sample only what's visible.
- Nav order: Processes, Performance, App history, Startup apps, Users, Services.
- One commit per feature. Test in the background only: no windows to the front, no visible Finder or DMG mounts.
- At the end: light and dark screenshots of each new page in screenshots/, a footprint table per page,
  ./scripts/make-dmg.sh.

## Status
1. **Services: code done, in this branch; not reviewed visually.** Adds Sampling/ServiceScanner.swift,
   Views/ServicesView.swift, `Shell` (moved out of StartupScanner; stdout and stderr combined;
   `runAsAdministrator` quotes arguments) and `ListCell` in Design.swift.
   - Tested with a harness on a throwaway `launchctl submit` job: listing, restart (new PID), stop and start pass.
     905 services listed; a scan takes about 150 ms, reading 906 plists about 135 ms, both off the main thread.
   - Not tested: the UI (no screenshot taken yet), the admin prompt path for system services, RAM.
   - Nav: currently appended last. Insert in the order above once App history and Users exist.
   - Stopping a system service without admin gives "Not privileged to signal service."
2. **Users: not started.** Plan:
   - Add `uid` to ProcessRow (kinfo_proc e_ucred.cr_uid is already read in ProcessSampler).
   - Reuse ProcessLine (make it and CellFrame non-private). Row = `ProcessGroup(main: synthetic row, children: processes)`.
     The synthetic row uses cpu/energy/rates -1 and memory 0, so `total` ignores it. Give it a negative id
     (-uid-1) so it can't clash with PIDs in `expanded`/`.id`. Pass the title explicitly (`group.title` counts main as a child).
   - Full name from getpwuid pw_gecos. A row needs a Fluent `.user` icon: add an optional Fluent param to
     ProcessLine (a template NSImage may not tint in dark mode).
   - Other users' processes are unreadable without root (rusage fails), so root and _xxx users show partial or "–" values.
   - Sampling: `samplesProcesses` is set in ProcessesView onAppear/onDisappear. With two pages using it the order
     of those callbacks isn't guaranteed. Move it to ContentView, driven by `page` (.processes or .users), and
     pass `monitor` as a plain `let` so ContentView doesn't redraw every tick.
3. **App history: not started.** Plan:
   - Sample every 10 s off the main thread: `proc_listallpids`, `responsibility_get_pid_responsible_for_pid`, then
     rusage only for processes whose responsible PID is a regular app (`NSWorkspace.runningApplications`).
   - Accumulate CPU time, `ri_energy_nj` and network deltas by bundle id. First pass is baseline only; later new
     processes count their full totals.
   - Network: split ProcessNetworkSampler so a one-shot `nettop` returns per-PID totals (cumulative; clamp deltas at 0).
   - Persist `{since, apps: {bundleID: {name, path, cpu, network, energy}}}` to
     ~/Library/Application Support/TaskManager/app-history.json every minute and on quit.
   - Page: Name with icon (from the saved path, on demand), CPU time, Network, Energy (Wh = nJ / 3.6e12),
     "Resource usage since <date>" caption, "Delete usage history" button (`.delete` icon is ready), sortable.
4. **GPU column: not started.** Findings:
   - Children of IOAccelerator have `IOUserClientCreator` = "pid 419, WindowServer" and
     `AppUsage` = array of {API="Metal", accumulatedGPUTime (ns), lastSubmittedTime}; AppUsage may be empty.
   - GPU% = delta of summed accumulatedGPUTime per PID / wall delta. Heat-shade like CPU; header total from
     `monitor.gpus`. Read only while Processes/Users is visible; measure the cost (100-200 clients).
   - Add `.gpu` (on by default), optional `.gpuEngine` (API name), `.diskRead`, `.diskWrite` (split the disk counters in
     ProcessSampler). Rename the AppStorage key to "processHiddenColumnsV2" with the new optional columns hidden by default.
5. **Battery: not started.** Findings on this Mac (MacBook, battery present):
   - AppleSmartBattery has TimeRemaining, ExternalConnected, AvgTimeToEmpty, Voltage (mV), MaxCapacity=100 (a percentage),
     CurrentCapacity (percent), CycleCount, InstantAmperage, Amperage (mA), FullyCharged, IsCharging.
   - Real capacities are nested: BatteryData = {NominalChargeCapacity 6484, DesignCapacity 6249, ...}. Health = nominal / design,
     clamped to 100%. Temperature is in 0.01 °C; check AdapterDetails.Watts.
   - Power W = V x A / 1e6, signed. UsageGraph clamps at 0, so add a `minValue` param (default 0) for the signed power graph.
   - Use IOPSCopyPowerSourcesInfo/List for charge, charging, power source, BatteryHealth; read single
     keys with `IORegistry.property`. Add a tile and `BatteryDetailView` like the other resources; only if a battery exists.

## Measuring (no hooks in the repo)
Copy the sources to a scratch folder and add a temporary hook there:
`setActivationPolicy(.accessory)`, `window.level = desktop level - 1`, `setFrame` to 1180x760, print the window number.
Launch with `-selectedPage <page>`, read `footprint -p <pid>`, capture with `screencapture -l<id> -o -x`.

## Other open items
- `dist/TaskManager.dmg` isn't rebuilt with these features.
- After leaving Processes, footprint stays at about 51-54 MB; the launch peak is about 128 MB (cause unknown).
- GitHub auth: repo-local credential config in .git/config (not in the repo, won't exist on another machine).
