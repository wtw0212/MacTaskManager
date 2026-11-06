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
2. **Users: code done (cloud, compiles on CI), not run yet.** UsersView.swift reuses ProcessLine/ProcessGroup;
   rows get negative IDs (Int32.min + uid). People (uid >= 500, no `_`) first with Active/Disconnected from
   SCDynamicStoreCopyConsoleUser, then "System accounts". Process sampling is now switched by ContentView for
   .processes and .users.
3. **App history: code done, not run yet.** Sampling/AppHistory.swift (10 s timer on main, rusage + one-shot
   nettop on a queue, baseline first pass, saves every minute and on quit to
   ~/Library/Application Support/TaskManager/app-history.json). Views/AppHistoryView.swift.
4. **GPU and disk columns: code done, not run yet.** Sampling/ProcessGPUSampler.swift. CHECK on the Mac that
   accumulatedGPUTime really is in nanoseconds: summed per-process GPU % should roughly match the GPU tile.
   If it's ~41x too small it's 24 MHz ticks. AppStorage key is now "processHiddenColumnsV2".
5. **Battery: code done, not run yet.** Sampling/BatterySampler.swift, Views/BatteryDetailView.swift. Graph is
   |battery power| (no signed graph). CHECK: Temperature scale (0.01 °C), Amperage sign, AdapterDetails name.

## Checked on an M5 Pro on battery, 2026-11-06 (release build, background)
- GPU: accumulatedGPUTime is nanoseconds. Sum of per-process GPU 33.4% vs Device Utilization 31.9% over 10 s. No fix needed.
- Disk write column: 464.7 MB/s vs iostat 467. Disk read column not confirmed (test missed the row).
- Users: rows, Active, expanding (via search) work. System accounts show "–" for CPU/memory/disk without root.
- App history: rows after one 10 s tick; file written at 59 s and on quit; CPU time matches ps.
- Battery: registry has no Temperature key here, so it now comes from the gas gauge HID sensors (27-31 C). Time
  remaining now comes from IOPowerSources and matches pmset. System power uses SystemLoad (SystemPowerIn is 0 on
  battery). The registry updates about every 60 s, so the power graph is a staircase. IOPowerSources has no
  BatteryHealth here, so the Condition row is hidden.
- Not tested: charging, adapter name and watts (Mac stayed on battery); Services UI; End task on Users.
- Footprint after 45 s: Performance 32 MB, App history 34 MB, Users 49 MB, Processes 65-72 MB. Side by side, main is
  57-65 MB and this branch 61-72 MB on Processes, about 6 MB more; with history, GPU sampling and battery off it
  matches main (58-60 MB).

## Measuring (no hooks in the repo)
Copy the sources to a scratch folder and add a temporary hook there:
`setActivationPolicy(.accessory)`, `window.level = desktop level - 1`, `setFrame` to 1180x760, print the window number.
Launch with `-selectedPage <page>`, read `footprint -p <pid>`, capture with `screencapture -l<id> -o -x`.

## Other open items
- `dist/TaskManager.dmg` isn't rebuilt with these features.
- After leaving Processes, footprint stays at about 51-54 MB; the launch peak is about 128 MB (cause unknown).
- GitHub auth: repo-local credential config in .git/config (not in the repo, won't exist on another machine).
