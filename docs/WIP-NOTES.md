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

All of the above built on GitHub Actions (macos-15, warnings as errors) but have not been launched.
Next on the Mac: run each page in the background, check values, screenshots, footprint table, DMG.

## Measuring (no hooks in the repo)
Copy the sources to a scratch folder and add a temporary hook there:
`setActivationPolicy(.accessory)`, `window.level = desktop level - 1`, `setFrame` to 1180x760, print the window number.
Launch with `-selectedPage <page>`, read `footprint -p <pid>`, capture with `screencapture -l<id> -o -x`.

## Other open items
- `dist/TaskManager.dmg` isn't rebuilt with these features.
- After leaving Processes, footprint stays at about 51-54 MB; the launch peak is about 128 MB (cause unknown).
- GitHub auth: repo-local credential config in .git/config (not in the repo, won't exist on another machine).
