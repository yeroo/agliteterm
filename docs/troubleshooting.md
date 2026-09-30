# Troubleshooting

## The log

agliteterm keeps a small always-on log of its own decisions — session saves and restores (with
counts, byte totals, and the exact error when a write fails), focus handoffs, and font and pack
resolution — at `%LOCALAPPDATA%\agliteterm\agliteterm.log` (`agliteterm-<instance>.log` for named
instances), rotating at about 1 MB into `.log.old`. It records what the client *did*, never terminal
output, pasted text, or your command lines, so it is safe to attach to an issue. A `save ok` line
means the state file changed: a tree change whose bytes are already on disk writes nothing and logs
nothing. A save blocked inside the filesystem (a rename held by an endpoint-security filter) also
logs nothing until it returns, so a quiet log is either a stable window or a stuck save. What tells
the two apart is `sessions.tsv.tmp` beside the state file: a stuck save has already written it and
is waiting to publish it, so a `.tmp` newer than `sessions.tsv` while the window is idle is a
publish that has not returned. A stable window leaves no `.tmp` behind.

## Reporting a problem

Run `agliteterm --diagnose` and attach its output plus `agliteterm.log`. The report is read-only and
safe to run while agliteterm is open. It prints the state file's path, whether that directory is
genuinely writable (a real write probe, which is what catches a redirected or policy-locked profile),
the state file's contents and its `.bak` generation, the resolved font, and the bundled pack
inventory:

```
> agliteterm --diagnose
  version: 0.17.2
  instance: (default)
  restart cmdline: "C:\Users\you\AppData\Local\Programs\agliteterm\agliteterm.exe"
state
  dir: C:\Users\you\AppData\Local\agliteterm
  dir writable: yes
  session file: ...\sessions.tsv
    size: 59 bytes
    modified: 2026-07-31 20:14:02
  backup file: ...\sessions.tsv.bak (59 bytes)
```

Use `--pipe <instance> --diagnose` to ask about a named instance: it reports *that* instance's state
file, which is the one its window restores from.

## "My sessions are gone"

Usually right sessions, wrong window: each `--pipe` instance restores only its own state file. See
[session restore](session-restore.md), including how to recover a generation by hand.

## "pty-host did not become usable"

If agliteterm exits at startup with this message, a previous `agwinterm-ptyhost.exe` is wedged: end
it in Task Manager and relaunch. `agliteterm.log` records the connection attempt by attempt, including
the case it is really there for — a host left dying by a killed window, which answers a handshake for
a moment while refusing every real command.

## A program does not see the terminal's colors

Codex shades your messages only when the terminal answers its color query, which needs
`agwintermctl config set conpty bundled` and a restart of the pty-host (close every window). That
ConPTY does not repaint a pane after a resize, which is why it is not the default: see
[the ConPTY shells run on](configuration.md#the-conpty-shells-run-on). With it set, look in
`agliteterm.log` for the `pty-host:` line of the launch that started the host:

- `started with --conpty bundled (conpty.dll and OpenConsole.exe are beside the exe)` is the expected
  case. It says what agliteterm asked for and found, not what the host loaded: if colors are still
  missing, check that a process named `OpenConsole.exe` runs under `agwinterm-ptyhost.exe` (Task
  Manager, Details). With none, the dll did not load (blocked or damaged): reinstall.
- `conpty.dll or OpenConsole.exe is missing` means the files beside `agliteterm.exe` are incomplete:
  reinstall.
- `started with --conpty inbox` means `conpty` was `inbox` (the default) when that host started.
- No such line means this window connected to a host that was already running, which keeps the
  ConPTY it started with until its last window and shell are gone.

Report bugs in [Issues](https://github.com/yeroo/agliteterm/issues).
