# ISSUE: New Window Focus And Startup Latency (KDE Wayland)

## Environment
- OS: Linux
- Desktop: KDE Plasma
- Session: Wayland (`kwin_wayland`)

## Current Product Scope
- Single terminal window (no tabs)
- `Ctrl+Shift+N` opens a new terminal window
- New window uses active terminal current directory on Linux (`/proc/<pid>/cwd`)

## Reported Problems
1. New terminal window opens with noticeable delay.
2. New terminal window can open behind current window (no foreground focus).
3. Earlier top-bar alignment issue (title/buttons vertical centering) was fixed.

## Debug Evidence Collected
- Keybinding path works:
  - `Ctrl+Shift+N` detected
  - spawn log emitted (`spawned direct pid=...`)
- Problem is post-spawn window mapping/focus policy, not key capture.

## Fixes Already Attempted
1. `Ctrl+Shift+N` implementation as new process spawn.
2. Executable path caching for repeated spawn calls.
3. Startup focus pulse in spawned window:
   - `show()`
   - repeated `setAlwaysOnTop(true/false)` + `focus()`
4. KDE-specific `kstart5` launcher path (reverted due failures/overhead).
5. Linux runner optimization:
   - show/present window immediately instead of waiting first Flutter frame.
6. Top bar control responsiveness/centering improvements.

## Current Workaround Added
- On KDE Wayland only, after spawning the new window, current window minimizes to hand off foreground to the new one.
- Shell startup now starts after first frame to reduce perceived startup delay.

## Remaining Risk
- Wayland compositors can enforce focus-stealing prevention; true foreground activation is policy-limited.
- If compositor blocks activation, app-level focus calls may still be ignored.

## Next Investigation (if needed)
1. Replace process-per-window with native multi-window strategy for direct activation inside one process.
2. Add optional user setting:
   - `New Window Behavior: Minimize current window on open` (currently implicit on KDE Wayland).
3. Consider KDE-specific DBus scripting integration if acceptable complexity.
