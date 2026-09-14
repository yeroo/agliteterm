# Troubleshooting

## The log

agliteterm keeps a small always-on log of its own decisions — session saves and restores (with
counts, byte totals, and the exact error when a write fails), focus handoffs, and font and pack
resolution — at `%LOCALAPPDATA%\agliteterm\agliteterm.log` (`agliteterm-<instance>.log` for named
instances), rotating at about 1 MB into `.log.old`. It records what the client *did*, never terminal
output, pasted text, or your command lines, so it is safe to attach to an issue.

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

Report bugs in [Issues](https://github.com/yeroo/agliteterm/issues).
