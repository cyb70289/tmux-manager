from __future__ import annotations

import subprocess
from dataclasses import dataclass
from typing import List, Optional, Sequence

from .config import is_valid_host


@dataclass(frozen=True)
class CommandResult:
    status: int
    stdout: str
    stderr: str
    timed_out: bool = False

    @property
    def combined(self) -> str:
        out = self.stdout.strip()
        err = self.stderr.strip()
        if out and err:
            return f"{out}\n{err}"
        return out or err


def run_command(
    argv: Sequence[str],
    timeout: Optional[float] = None,
    env: Optional[dict[str, str]] = None,
) -> CommandResult:
    try:
        proc = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            env=env,
        )
        return CommandResult(
            status=proc.returncode,
            stdout=proc.stdout or "",
            stderr=proc.stderr or "",
            timed_out=False,
        )
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout.decode("utf-8", errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        err = exc.stderr.decode("utf-8", errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        return CommandResult(status=124, stdout=out, stderr=err, timed_out=True)
    except OSError as exc:
        return CommandResult(status=-1, stdout="", stderr=str(exc), timed_out=False)


@dataclass(frozen=True)
class ProbeResult:
    kind: str  # "ok" | "tmux_missing" | "unverified" | "failed"
    detail: str = ""

    @property
    def summary(self) -> str:
        if self.kind == "ok":
            return f"Connected. Remote tmux: {self.detail}"
        if self.kind == "tmux_missing":
            return "Connected, but tmux was not found on the remote host."
        if self.kind == "unverified":
            return f"Could not verify automatically ({self.detail}). You can still save."
        return f"Connection failed: {self.detail}"


def probe_ssh(
    host: str,
    ssh_options: Sequence[str] = (),
    timeout: float = 25.0,
) -> ProbeResult:
    """Advisory ssh + tmux check; never raises, never blocks saving."""
    if not is_valid_host(host):
        return ProbeResult("failed", "invalid host")
    argv: List[str] = [
        "/usr/bin/ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        *ssh_options,
        host,
        "bash -lc 'command -v tmux >/dev/null 2>&1 && tmux -V || echo NO_TMUX'",
    ]
    result = run_command(argv, timeout=timeout)
    text = result.combined
    if result.timed_out:
        return ProbeResult("failed", f"timed out after {int(timeout)}s")
    if "NO_TMUX" in text:
        return ProbeResult("tmux_missing")
    if result.status == 0:
        version = text.splitlines()[0] if text.splitlines() else "tmux"
        return ProbeResult("ok", version)
    lower = text.lower()
    if "permission denied" in lower or "host key verification failed" in lower:
        return ProbeResult("failed", text)
    if any(
        token in lower
        for token in (
            "batchmode",
            "no more authentication methods",
            "passphrase",
            "password",
        )
    ):
        return ProbeResult("unverified", "interactive authentication required")
    return ProbeResult(
        "failed",
        text if text else f"ssh exited with status {result.status}",
    )
