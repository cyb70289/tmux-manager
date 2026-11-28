# TmuxManager (Linux X11 + WezTerm)

A floating X11 bar that keeps a list of `host : tmux session` entries and opens each one in its own WezTerm window over `ssh`. Click a pill to open or raise the console, `⟳` to reconnect in place, right-click to close, open plain ssh, edit, or remove.

Requirements: Ubuntu 22.04 (or similar Linux X11 desktop), `wezterm`, `ssh`, `tmux` on remote hosts, Python 3 with GTK 3 + libwnck3 (`python3-gi`, `gir1.2-gtk-3.0`, `gir1.2-wnck-3.0` — installed by default on Ubuntu desktop).

## Install and run

```sh
make test      # unit and wrapper tests
make install   # install to ~/.local/bin/tmux-manager + desktop launcher
make run       # run directly from this directory
```

Launching `tmux-manager` while already running raises the existing bar.

## Use

- `+` (or `Ctrl+N`) adds an entry (`Name`, `SSH host`, `tmux session`, optional `tmux path` / `Extra ssh options` / `-D`). Saving runs an advisory ssh + tmux check that warns on failure without blocking.
- Click a gray pill to open a WezTerm console, or a green pill to raise/unminimize the existing window (switching workspace if needed). Spinner = opening or reconnecting.
- Green pill shows `⟳`: restarts `ssh` in the same window. Right-click → `Close` / `Plain SSH` / `Edit…` / `Remove…`.
- `Plain SSH` opens an unmanaged WezTerm window running `ssh` to the entry's host with its `ssh_options`.
- `Close` captures and saves the window's X11 geometry immediately, then closes the window while leaving the remote tmux session running.
- `Remove…` asks whether to also kill the remote tmux session (checked by default).
- Drag the bar by its background to reposition it; its right edge stays pinned as entries are added or toggled. `Ctrl+Q` quits cleanly and saves open window frames.

## How it works

```
tmux-manager (GTK 3 + Wnck) ──spawn──► wezterm start --always-new-process --class tmux-manager-<id>
      │                                                   │
      │                                             attach.sh <uuid>
      │                                                   │
      └── reads state files, sends signals,               └── ssh -t host 'tmux new-session -A [-D] -s SESSION'
          raises/captures/closes via X11 EWMH
```

- Each entry launches with its own `--always-new-process --class tmux-manager-<id>`, inheriting `~/.wezterm.lua` while overriding only `exit_behavior="Close"` and `window_close_confirmation="NeverPrompt"`.
- Liveness is file-based: an entry is open when `state/<uuid>.json` exists and `/proc/<pid>/cmdline` still matches `attach.sh <uuid>`.
- Window frames are captured via `libwnck` on a timer (default 30 s) and on activate/reconnect/close/quit, and restored via `--position` plus EWMH geometry clamped to visible X11 monitor workareas.

## Files

Support directory: `${TMUX_MANAGER_DIR:-~/.local/share/tmux-manager}`

| Path | Purpose |
| --- | --- |
| `config.json` | entries, saved frames, bar origin (schema-compatible with macOS) |
| `env/<uuid>.sh` | generated per-entry shell variables sourced by `attach.sh` |
| `state/<uuid>.json` | written by `attach.sh` while a console is open |
| `attach.sh` | console wrapper installed/updated on launch |
| `log.txt` | app + wrapper log, rotated at 1 MB |
| `control.sock` | single-instance IPC socket (and `--debug` test channel) |

Hand edits to `config.json` are picked up within 1 second.

## Source map

| Path | Responsibility |
| --- | --- |
| `tmux_manager/config.py` | config/entry schema, validation, quoting, window class naming |
| `tmux_manager/config_store.py` | atomic `config.json` load/save, env file generation, stat polling |
| `tmux_manager/state_store.py` | wrapper state files and `/proc/<pid>/cmdline` liveness verification |
| `tmux_manager/frame_clamp.py` | X11 screen clamping and right-edge bar placement |
| `tmux_manager/shell.py` | subprocess runner and advisory `probe_ssh` |
| `tmux_manager/x11_windows.py` | `Wnck`/`Gdk` X11 window lookup, raise, geometry get/set, close |
| `tmux_manager/terminal_controller.py` | WezTerm command builder, clean-env spawn, frame restore |
| `tmux_manager/app_model.py` | entry orchestration, timers, frame capture, hot reload |
| `tmux_manager/bar_ui.py` | GTK 3 floating bar, pills, context menu, drag and pinning |
| `tmux_manager/entry_editor.py` | floating add/edit dialog |
| `tmux_manager/ipc.py` | Unix socket single-instance and debug server |
| `resources/attach.sh` | console wrapper |

## Gotchas

- X11-only: raising existing windows, bar positioning, and frame capture/restore require X11 EWMH and do not work under Wayland.
- Frame restore is best-effort: some window managers (and remote XQuartz) may adjust or clamp requested window positions/sizes.
- Spawning WezTerm strips `WEZTERM_UNIX_SOCKET`, `WEZTERM_PANE`, `TMUX`, and `TMUX_PANE` from the child environment so managed windows never attach to a parent terminal session.
- `--debug` (or creating an empty `debug` file in the support dir) enables scripted control via `./tmux-manager --send '{"action":"status"}'`.
