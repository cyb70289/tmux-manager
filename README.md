# TmuxManager

A small macOS bar that keeps a list of `host : tmux session` entries and opens each one in its own iTerm2 window over `ssh`. Click a button to open or raise the console, `⟳` to reconnect without losing the window, right-click to close, edit or remove.

Typical use: long-lived tmux sessions on a few remote hosts, each one click away. The bar remembers each window's on-screen position/size and reattaches exactly there. It only drives your existing iTerm2 — no new console app, nothing else to keep running.

Requirements: macOS 13+, iTerm2, system `ssh`, `tmux` on the remote host. No other dependencies — the app shells out to `ssh` and drives iTerm2 with AppleScript.

## Build and run

```sh
make test      # unit tests
make install   # build, ad-hoc sign, copy to /Applications
make run       # install + launch
```

The first AppleScript call triggers macOS Automation permission for iTerm2. Ad-hoc signing means a rebuilt app looks like a new program, so expect that prompt again after each rebuild.

## Use

- `+` adds an entry (name, ssh host, tmux session, optional tmux path / extra ssh options / `-D`). Saving runs an advisory check: can we ssh and is tmux installed? A failure warns but never blocks saving.
- Click a button: opens a console, or raises the existing window (de-miniaturizes and switches Space as needed).
- Gray = no console. Green = console window open. Spinner = opening.
- Green button shows `⟳`: restarts ssh in the same window. Right-click → activate / reconnect / close / edit / remove.
- `Close Console` (right-click, only while the console is open) reads the window's current position/size, saves it immediately, then closes the window. The remote tmux session survives. This is the frame-accurate way to close: unlike the traffic-light `×`, nothing is lost even if the window was moved/resized seconds ago.
- Removing asks whether to also kill the remote tmux session (unchecked by default).
- Buttons are ordered by name; the bar is draggable and remembers its position. Its right edge is pinned: adding, editing or opening an entry grows the bar to the left, and it only slides right again when it would no longer fit on screen. Per-entry window frames are captured while a console is open and restored on the next open, clamped to the visible screens.

## How it works

```
TmuxManager.app ──AppleScript/osascript──► iTerm2 window
      │                                        │
      │                                  attach.sh <entry-uuid>
      │                                        │
      └── reads state files, sends signals      └── ssh -t host 'tmux new-session -A -s SESSION'
```

The app never runs ssh for a console: it hands each window to `attach.sh`, which owns the connection and records itself on disk.

### Wrapper contract (`Resources/attach.sh`, installed to the support dir)

- Started by iTerm2 as `<support>/attach.sh <entry-uuid>`; takes no other arguments.
- Sources `<support>/env/<uuid>.sh` (generated from config) on every connect, so config edits apply on the next reconnect.
- Writes `<support>/state/<uuid>.json` (`wrapper_pid`, `ssh_pid`, `iterm_session_id`, `tty`).
- `SIGUSR1` → kill ssh, restart it in place. That is what `⟳` does. Exit-137 fallback for a manually killed ssh.
- ssh exit 0 → detach/end → window closes. Other statuses → message + `[Enter] retry` prompt.
- `SIGHUP`/`SIGTERM` (window closed) → kill ssh, remove state file. iTerm2 sends SIGHUP roughly 5 s after a window closes.

Liveness is therefore file-based: the app treats an entry as open when its state file exists *and* the pid still runs `attach.sh <uuid>` (verified through `KERN_PROCARGS2`, so pid reuse cannot fool it). No liveness probing of the host is done; nothing reconnects on its own.

### Frames

While any console is open, the app polls iTerm2 for window bounds in-process (`NSAppleScript`, `frame_capture_interval_seconds`, default 30 s) and persists changed frames to config (debounced, plus on activate/reconnect/quit). `Close Console` captures and saves the frame at the instant of closing, so it does not depend on the poll. Restore clamps frames to `NSScreen.visibleFrame` — a frame that is less than 25 % visible is moved onto the nearest screen.

### iTerm2 profile

`~/Library/Application Support/iTerm2/DynamicProfiles/TmuxManager.json` is written at launch: a partial profile inheriting your **current default iTerm2 profile**, regardless of its name, including fonts, colors, encoding and locale settings. Only "Close Sessions On End" and the close prompt are overridden. No explicit parent is set: a profile named `Default` need not exist. Do not rename the generated profile; `TerminalController` recreates it if iTerm2 forgets it. Close and reopen existing consoles to apply profile changes; reconnect only restarts ssh.

## Files

Support directory: `~/Library/Application Support/TmuxManager/`

| Path | Purpose |
| --- | --- |
| `config.json` | single human-readable state: entries, last frames, bar position |
| `env/<uuid>.sh` | generated per-entry shell variables (do not edit) |
| `state/<uuid>.json` | written by the wrapper while a console is open |
| `attach.sh` | the wrapper (reinstalled from the bundle at launch) |
| `log.txt` | app + wrapper log, rotated at 1 MB |

```json
{ "version": 1,
  "ui": { "bar_origin": {"x": 1380, "y": 1009}, "frame_capture_interval_seconds": 30 },
  "entries": [
    { "id": "…", "name": "build box", "host": "cyb@devbox", "session": "main",
      "tmux_path": null, "ssh_options": [], "detach_other_clients": false,
      "frame": {"x": 400, "y": 300, "w": 800, "h": 600} } ] }
```

Frames use AppleScript `bounds` space: top-left origin, y growing downward from the primary display. Hand edits to `config.json` are picked up within a second.

## Source map

| Path | Responsibility |
| --- | --- |
| `Sources/TmuxManagerCore/Config.swift` | entry/config model, defaults, validation |
| `Sources/TmuxManagerCore/ConfigStore.swift` | atomic load/save, env-file generation, file watcher |
| `Sources/TmuxManagerCore/StateStore.swift` | wrapper state files, pid→argv validation |
| `Sources/TmuxManagerCore/AppleScripts.swift` | AppleScript builders + frame-line parser |
| `Sources/TmuxManagerCore/ProfileInstaller.swift` | dynamic profile inheriting iTerm2's default settings |
| `Sources/TmuxManagerCore/FrameClamp.swift` | on-screen clamping and coordinate conversion |
| `Sources/TmuxManagerCore/Shell.swift` | subprocess helper, `osascript`, ssh probe |
| `Sources/TmuxManager/AppModel.swift` | orchestration: open/activate/reconnect/add/edit/remove, timers |
| `Sources/TmuxManager/TerminalController.swift` | osascript calls to iTerm2, launch and profile recovery |
| `Sources/TmuxManager/BarUI.swift` | bar window/view, entry capsule, context menu |
| `Sources/TmuxManager/EntryEditor.swift` | add/edit window (not a sheet: a sheet would push the bar off its pin) |
| `Resources/attach.sh` | the wrapper |

## Gotchas

- AppleScript needs the Automation grant; if iTerm2 is not running the app starts it first, writing iTerm2's `quiet` marker (`~/Library/Application Support/iTerm2/quiet`) so the launch produces only the console window — no extra untitled iTerm2 window.
- `attach.sh` validates session names (`[A-Za-z0-9_.-]`) because the name travels through a remote shell.
- `-D` (detach other clients) is on by default: it silently kicks clients attached from other machines, which also fixes window-size shrinking caused by stale clients.
- Clicking a gray button opens a *new* window; a console closed seconds ago may still have a live wrapper (iTerm2's SIGHUP delay), so the new window replaces the state file and the old wrapper leaves it alone.
- `--debug` (or an empty `debug` file in the support directory) enables a distributed-notification hook for scripted testing:
  `osascript -l JavaScript tools/post-debug.js open <uuid>` (see `tools/post-debug.js`).
