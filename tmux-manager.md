# tmux Session Manager for iTerm2: Requirements and Initial Design

Status: draft, personal-use scope. Platform: macOS only, iTerm2 only.

## 1. Purpose

A small macOS GUI app that keeps a list of remote `host : tmux session` entries and uses iTerm2 as the console. It does not embed a terminal and does not use any SSH or tmux library: it only invokes the local `ssh` binary, which runs `tmux` on the remote host.

## 2. Scope

In scope:

- Managing a configured list of remote hosts and tmux sessions.
- Opening a console for an entry, or activating the existing one.
- Forcing a reconnect of an already open session without closing its window.
- Remembering and restoring window size and position per entry.

Out of scope:

- Specific UI layout and user-experience behaviour.
- Linux, Windows, other terminal emulators.
- Embedded terminal rendering (libghostty and similar).
- Automatic liveness probing, automatic reconnect, wake-from-sleep detection.
- tmux control mode, window and pane management inside tmux.

## 3. Requirements

### 3.1 Functional

| ID | Requirement |
| --- | --- |
| F1 | The user can add, edit, and remove entries. An entry has: display name, ssh host (an alias from `~/.ssh/config` or `user@host`), tmux session name, and optional overrides (remote tmux path, extra ssh options). |
| F2 | On request, the app opens an iTerm2 window attached to the entry's tmux session, creating the tmux session if it does not exist. |
| F3 | If a console for that entry is already open, the request brings that window to the front instead of opening a second one. |
| F4 | The user can force reconnect an open session. The ssh process is replaced; the iTerm2 window, its size, and its position are kept. The remote tmux session is unaffected. |
| F5 | Window size and position are remembered per entry and restored the next time the console is opened. |
| F6 | The app shows whether each entry currently has an open console window. |

### 3.2 Non-functional

- Only external dependencies are the system `ssh`, remote `tmux`, and iTerm2.
- Reuse `~/.ssh/config` for keys, ports, ProxyJump, and agents; the app stores no credentials.
- Local state is a single human-readable config file.
- Failures (iTerm2 not running, automation permission denied, host unreachable) surface as clear messages and never leave orphaned processes.

### 3.3 UI

- A movable horizontal bar (default to screen top right)
- With a "+" button to add new host:session
  * create a config entry, test the ssh connection and if tmux is installed on remote host
  * host:session config is still there even if that session is killed, it's just a static config
- One button for each configured session, named "host:session"
  * black if no active window, green if run in a local iterm2 console
  * if not active, click the button to create a new item2 console, ssh and attach to remote session (create a new session if according session name is not available). if already active, click to active the window (bring to front and restore size if minimized)
  * an obvious and easy way to force reconnect an active session
  * can delete the session, option to choose kill remote tmux session or not (default not)
  * your call on how to handle reconnect and delete on ui conveniently, reconnect shall be easy to do, delete can be indirect in ui
- no need to scan or reconcile tmux sessions created out of our control, per configured session name, either attach to an existing one or create a new one
- user friendly for errors like connection timeout, no auto detection, only reponse when user explicitly connect or reconnect

## 4. Architecture overview

```
GUI app (list + config)
  |
  |-- config store (entries, saved window frames)
  |-- iTerm2 controller (AppleScript via osascript, or the iTerm2 Python API)
  |-- process helper (find and kill ssh by tty)
  |
  v
iTerm2 window  --runs-->  attach.sh (wrapper)  --runs-->  ssh -t host tmux new-session -A ...
```

The app talks to iTerm2 only to create windows, find windows, read tty and frame, and set frame. All terminal behaviour (rendering, input, scrollback, mouse) is iTerm2's and tmux's own.

## 5. Design ideas

### 5.1 Console command and wrapper

Each iTerm2 window runs a small wrapper script instead of ssh directly:

```
attach.sh <ssh-host> <tmux-session>
```

The wrapper loops around:

```
ssh -t -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o ConnectTimeout=10 \
    <host> "tmux new-session -A -D -s '<session>'"
```

and reacts to the exit status:

| Exit status | Meaning | Wrapper action |
| --- | --- | --- |
| 0 | User detached, or the tmux session ended | Exit, so the window closes |
| 137 | ssh killed by the app (force reconnect) | Reset terminal, restart ssh in the same window |
| other | Connection failure or ssh error | Print status and wait for Enter to retry or Ctrl-C to close |

Notes:

- `-A` attaches if the session exists and creates it if not.
- `-D` detaches a stale client left on the server by a dead connection. Drop it if the same session is attached from several machines.
- After any ssh exit the wrapper runs `stty sane` and a terminal reset, because killing ssh leaves the alternate screen, mouse reporting, and bracketed paste modes enabled.
- Session names are restricted to a safe character set (for example `[A-Za-z0-9_.-]`) because the command passes through the remote shell.
- Keepalive is a moderate backstop, not a liveness detector. The network has multi-second glitches, so ssh must not drop a healthy connection on short stalls.

### 5.2 Open or activate (F2, F3)

- On open, the app creates an iTerm2 window using a dedicated profile and the wrapper as its command. It records the iTerm2 session `unique id` and the window `tty` against the entry in memory.
- To activate, the app searches windows, tabs, and sessions for the stored `unique id`. If found: de-miniaturize the window, select the tab and session, then activate iTerm2 last. If not found (closed by the user, or iTerm2 restarted), it opens a new window.
- Windows are identified by session `unique id`, never by title, because shells and tmux can overwrite titles.
- After an app restart the in-memory ids are gone. Optionally the app can rediscover windows by tagging them (for example an iTerm2 session variable or a user-defined name set at creation) and matching on that.
- The dedicated iTerm2 profile is configured so that closing or ending a session does not prompt: prompt before closing set to never, and close the window when the session ends.

### 5.3 Force reconnect (F4)

- The app asks iTerm2 for the target session's tty (for example `/dev/ttys004`) and runs `pkill -9 -t ttys004 -x ssh`.
- SIGKILL is used deliberately: it produces exit status 137, which the wrapper recognizes as a requested reconnect. SIGTERM would give 255, indistinguishable from a real failure.
- The wrapper then resets the terminal and starts a new ssh, reattaching to the same tmux session. The window is never closed, so its frame is preserved.
- Killing a healthy connection is harmless: tmux keeps the session alive on the server, so the user only loses transient client state such as a half-typed command or copy mode.
- No liveness probe is involved. The user decides when to reconnect.

### 5.4 Remember window size and position (F5)

A closed window's frame cannot be read, so the frame must be captured while the window is open.

- **Capture:** while the app runs, it periodically (every few seconds) reads the bounds of each tracked window and writes changed values to the entry's saved frame. It also captures on activate, on force reconnect, and on app quit. Capturing when the app notices a window has disappeared is too late, so the periodic capture is what matters.
- **Restore:** after creating a window, set its bounds to the saved frame (AppleScript `bounds` property, or the iTerm2 Python API `async_set_frame`).
- **Display changes:** before applying, check the frame against the currently connected screens. If it is mostly or entirely off-screen (for example an external monitor was unplugged), clamp it into the visible area, or fall back to a default size.
- **Coordinate systems:** AppleScript bounds use a top-left origin, while Cocoa screen frames use a bottom-left origin. Convert consistently when clamping.
- Window arrangements built into iTerm2 are not used, because they snapshot all windows together and are keyed by profile rather than by entry.

### 5.5 Configuration

A single file (for example JSON or TOML under `~/Library/Application Support/<app>/`):

```
entries:
  - name: build-box
    host: devbox            # alias from ~/.ssh/config
    session: main
    tmux_path: null         # optional override
    ssh_options: []         # optional extra options
    frame: {x, y, w, h}     # last known window frame
```

Host details (ports, keys, jump hosts) stay in `~/.ssh/config`.

## 6. Known risks and catches

| Risk | Mitigation |
| --- | --- |
| macOS Automation permission prompt on first iTerm2 scripting call | Accept once; a signed or sandboxed build needs the Apple Events entitlement and usage description |
| Terminal left in a dirty mode after ssh is killed | Wrapper runs `stty sane` and a reset after every ssh exit |
| Stale server-side tmux client after a dead connection shrinks the window | Use `-D`, or set `window-size latest` in the remote tmux config |
| Window on another Space, or minimized, does not come forward | De-miniaturize and select tab and window explicitly; rely on the macOS setting to switch Spaces |
| Saved frame lands off-screen after a monitor change | Clamp to visible screens before applying |
| `pkill -t` affects the wrong process if the tty is reused | Match on `-x ssh` and the tty owned by the tracked session; refresh the tty from iTerm2 right before killing |
| Wrapper retry loops forever on a bad host or auth failure | Non-zero statuses other than 137 stop and wait for the user |
| Window ids lost when the app restarts | Tag sessions at creation and rediscover; otherwise open a new window |
| iTerm2 not running or scripting disabled | Detect and show an actionable error |

## 7. Open questions

- Implementation language and GUI toolkit (Swift and AppKit is the natural fit for AppleScript and screen handling).
- AppleScript versus the iTerm2 Python API for window control. AppleScript is simpler to start; the Python API is better if event-driven frame tracking is wanted.
- Whether to rediscover existing windows after the app restarts, or accept opening new ones.
- Whether `-D` should be on by default.
- Where the wrapper script lives and how the app installs it.

## 8. Suggested milestones

1. Wrapper script plus a manual iTerm2 open via AppleScript, to validate the console command, exit-status handling, and terminal reset.
2. Entry config and open-or-activate by session id.
3. Force reconnect by tty.
4. Frame capture and restore, including screen clamping.
5. Optional: session listing and rediscovery after restart.
