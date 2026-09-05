# The state file — `sessions.tsv`, line by line

What agliteterm writes to restore itself from, field by field, so a file can be read, hand-edited or
seeded by a test without reading `saveSessionState()` / `parseStateFile()` in `src/main.cpp`. The
README's *Session restore & the state file* section is the user-facing half (where the file is, the
`.bak` generation, how to recover by hand); this is the format.

Path: `%LOCALAPPDATA%\agliteterm\sessions.tsv` for the default instance, `sessions-<instance>.tsv`
for a `--pipe <instance>` window. One file per window process. Tab-separated UTF-8 text, `\n`
line ends (`\r` is tolerated on read), no BOM. A field never contains a tab, a newline or a carriage
return: the writer replaces each with a space (`tsvField`), and there is no escaping — which is why
an "empty field" is a real value and an absent line is the only way to say "none" (see `C`).

## Line types, in the order they are written

| Line | Fields | Meaning |
| --- | --- | --- |
| `V1` | — | The header. Always first. The number has never changed: the format grows by adding line types, not by bumping it. |
| `W` | `name` | One workspace, in tree order. The first `W` is workspace `0`. |
| `S` | `ws` `name` `app` `cwd` `arg`… | One visible session, in tree order. `ws` indexes the `W` lines; `name` is empty when the session was never named (it shows as `session N`); `app`, `cwd` and the args are the **launch spec** — what is relaunched, never what was running inside. `cwd` is the shell's *live* directory when it was readable and fits the pty-host's 260-byte field, the creation directory otherwise. |
| `F` | `i`… | The indices, among the `S` lines, of the flagged sessions. Absent when none. |
| `D` | `id`… | The pty-host session id of every `S` line, in order. Lets a relaunch after a kill **adopt** a shell the host still holds instead of starting a new one. Absent in files from before 0.17.x builds that wrote it; the count must equal the `S` count or the whole line is ignored. |
| `C` | `i` `text` | The **context** of the session at `S` index `i` (parity batch P3, `session context`). One line per session that has one; no line for a session without one, because an empty field could not tell "no context" from a context that is empty. Written after `D`, before `P`. |
| `P` | `owner` `app` `cwd` `arg`… | The **split shell** of the session at `S` index `owner`: its own launch spec. One line per session that has a split. |
| `K` | `i` `pane0` `pane1` | The **captured commands** of the session at `S` index `i` (parity batch P3, `restore capture`): `pane0` is the slot of the session's own shell, `pane1` the slot of its split shell (empty when there is no split, or nothing was captured there). An empty field is "none"; a slot is a plain string with no rules of its own, so unlike `C` one line carries both panes. One line per session with at least one slot. Written **after** the `P` lines, because `pane1` belongs to the split the `P` line rebuilds. A slot is a checkpoint a caller reads back (`tree --json`, `capturedCommands`); lite never types it into the shell. |
| `A` | `ws` | The active workspace. Clamped on load to the workspaces the file has. |
| `O` | `ws` | The focused workspace. Read when present; this build does not write it. |

A file written by the current build, one workspace, two sessions, the first with a context, a split
and a captured command in each pane:

```
V1
W	main
S	0	build	pwsh.exe	C:\src\app
S	0		pwsh.exe	C:\src
F	0
D	a1b2c3d4-…	e5f6a7b8-…
C	0	reviewing the P3 diff
P	0	pwsh.exe	C:\src\app\tests
K	0	npm test	ping -n 3 127.0.0.1
A	0
```

## The rules the reader applies

- **Unknown line types are ignored**, and the lines it knows are honoured. That is what lets an
  older build read a newer file (it restores the sessions and drops what it cannot carry — and
  writes the file back without those lines on its next save, so a downgrade loses contexts, splits
  and slots, not sessions) and a newer build read an older one (a file from before P3 has no `C` or
  `K` and restores exactly as it did).
- **A malformed `S` line still counts.** `C`, `P`, `K` and `D` index sessions by *position* among the
  `S` lines, so a session line the reader could not parse shifts every index after it. Rather than
  hang a context, a split or a slot on the wrong session, each of those sets is refused **wholesale**
  when the number of `S` lines differs from the number that parsed, with one `logWarn` naming both
  counts (`state: 2 session line(s) but 1 parsed - refusing 1 context line(s) rather than attaching
  them to the wrong sessions`). Every parseable session still restores.
- **An index past the `S` list** (a hand-shortened file) drops that one line, named in the log; the
  sessions it does not name are untouched.
- **A loaded context goes through the verb's own rules** — trimmed, not blank, no control character,
  at most 200 characters. One that fails is dropped on load with one `logWarn` naming the session
  and the refusal (`restore: context for session 'x' dropped - session context: control character
  U+0001 at offset 3 …`); the session restores without it and nothing is drawn.
- **A `K` slot lands on the session the restore creates**: `pane0` on the session, `pane1` on the
  split the matching `P` line rebuilds. When that split did not come back — the `P` set was refused,
  or the split failed to start — the `pane1` slot has no pane to belong to and is dropped with a
  `logWarn` naming the session. A session whose app failed to start keeps its `pane0` slot the way it
  keeps its name, and re-saves both.
- **`.tmp`, then rename, one `.bak`.** The save writes `sessions.tsv.tmp`, rotates the current file
  to `sessions.tsv.bak` and renames the temp over the target. A zero-session save over a populated
  file is refused (the log says so); the one legitimate empty is the user closing the last session.
  Any thread may save — the UI thread on every tree change and at quit, the control-pipe thread
  after `restore capture` so the verb's reply describes a file that already exists — serialised by
  one lock around the write and the rename.
- **Restore order**: `sessions.tsv`, then `.bak` when the primary is missing, empty or parses to no
  sessions, then a fresh window.

`test/restore-matrix.ps1` seeds these files byte for byte and asserts the branches above (a
control character in a `C` line, a `C`/`P`/`K` count mismatch, a stray index, a pre-P3 file, a
truncated write, a `.bak` fallback, a future line type); `test/control-honesty.ps1` reads the `C`
and `K` lines back after each verb.
