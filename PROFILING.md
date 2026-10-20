# CPU audit — 2026-10-17

## Evidence

- Prior installed build: approximately 7–9% CPU in short top samples.
- Five-second macOS `/usr/bin/sample` profile: the communications queue repeatedly
  queried `NSRunningApplication.bundleIdentifier` and `localizedName` across all
  running apps. The latter entered LaunchServices `_fetchDynamicProperties` and
  synchronous IPC. Accessibility scans and CoreAudio queries also appeared.
- Stack sample counts include waiting, not just CPU execution; they are not CPU
  percentages. Media subprocess waits likewise do not imply busy-loop CPU use.

## Fix

- Cache only supported app identities and PIDs; refresh on workspace launch/exit
  notifications, with a 60-second fallback for background agents.
- Fetch display names only after filtering supported bundle identifiers.
- Poll snapshots of this small cache rather than querying all running apps.
- Skip CoreAudio queries when an app has no windows.
- Preserve message scanning, active call scanning, and existing hover behavior.

## Verification

- Release build, signed installation and existing regression suite passed.
- Six valid post-install samples, three seconds apart: 0.6, 0.9, 0.8, 0.8,
  0.7, 0.7 percent CPU (mean 0.75%). Discarded first top sample's 0.0 value.
- Follow-up five-second stack sample no longer showed the repeated
  `localizedName` / `_fetchDynamicProperties` path.
- Profiles: `/tmp/notchflow-cpu-before.txt`, `/tmp/notchflow-cpu-after.txt`.

## Limits

These are short observations of the user's existing session, not a controlled
battery benchmark. Do not translate the CPU difference into battery-life claims.
Playback, open Mini Dock, active calls, delivery of new messages, sleep/wake,
and launch/exit cache refresh still need extended interactive measurements.
The existing regression suite does not exercise live AX delivery or workspace
notification delivery end-to-end. Remaining periodic work includes the 30 Hz
pointer fallback and bounded AX scans; media helpers may add separate CPU cost.
