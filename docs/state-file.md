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
| `D` | `id`… | The pty-host id of every `S` line's **shell** (the session's `paneId`), in order. Lets a relaunch after a kill **adopt** a shell the host still holds instead of starting a new one. It is the session id too, except for a session promoted after its own shell closed (P4): that one kept the closed shell's id as its session id, and the adopting relaunch brings it back under its shell's id — the file records shells, not promotions. Absent in files from before 0.17.x builds that wrote it; the count must equal the `S` count or the whole line is ignored. |
| `C` | `i` `text` | The **context** of the session at `S` index `i` (parity batch P3, `session context`). One line per session that has one; no line for a session without one, because an empty field could not tell "no context" from a context that is empty. Written after `D`, before `P`. |
| `P` | `owner` `app` `cwd` `arg`… | The **split shell** of the session at `S` index `owner`: its own launch spec. One line per session that has a split. |
| `L` | `owner` `axis` `order` | The **layout** of the split of the session at `S` index `owner` (parity batch P4): `axis` is `vertical` (left/right panes) or `horizontal` (top/bottom panes) — the arrangement of the panes, never the divider, case-sensitive; `order` is `0` when the session's own shell sits in slot 0 (left/top) or `1` after a `session swap` put it in slot 1. Written **only when the layout is not the default** (horizontal, or swapped, or both), so a vertical unswapped split writes the exact bytes 0.17.14 wrote, and only for a session whose `P` line exists — the layout describes the pair. Written after the `P` lines, before `K`, by the same convention as `K`. **Downgrade**: an older build ignores `L` (unknown line types are ignored) and restores the split in the default layout — the `P` line is untouched, so a downgrade loses the layout, not the split — and drops the line on its next save. On load each field is validated on its own: an `axis` other than the two words restores `vertical`, an `order` other than `0` / `1` restores `0`, each named in the log; an `L` for an owner with no `P` line is dropped and named. |
| `K` | `i` `pane0` `pane1` | The **captured commands** of the session at `S` index `i` (parity batch P3, `restore capture`): `pane0` is the slot of the session's own shell, `pane1` the slot of its split shell (empty when there is no split, or nothing was captured there). An empty field is "none"; a slot is a plain string with no rules of its own, so unlike `C` one line carries both panes. One line per session with at least one slot. **The fields are by ROLE, not by position on screen**: `pane0` is always the session's own shell and `pane1` always the split shell, whatever slot each sits in — the `L` line carries the order, `K` does not repeat it. After a promotion (the session's own shell closed, the split shell became the session) the survivor's slot is `pane0`, because it is the session's own shell now. Written after the `P` lines by convention — `K` sits with the `P` lines it describes — not by requirement: the reader collects every line type in file order and applies them in its own fixed order, so a `K` above a `P` restores identically. A slot is a checkpoint a caller reads back (`tree --json`, `capturedCommands`); lite never types it into the shell. |
| `A` | `ws` | The active workspace. Clamped on load to the workspaces the file has. |
| `O` | `ws` | The focused workspace. Read when present; this build does not write it. |

A file written by the current build, one workspace, two sessions, the first with a context, a split
stacked top/bottom and swapped (its own shell in the bottom slot), and a captured command in each
pane:

```
V1
W	main
S	0	build	pwsh.exe	C:\src\app
S	0		pwsh.exe	C:\src
F	0
D	a1b2c3d4-…	e5f6a7b8-…
C	0	reviewing the P3 diff
P	0	pwsh.exe	C:\src\app\tests
L	0	horizontal	1
K	0	npm test	ping -n 3 127.0.0.1
A	0
```

The same file with the split left/right and unswapped has no `L` line at all — byte for byte what
the build before P4 wrote.

## The rules the reader applies

- **Unknown line types are ignored**, and the lines it knows are honoured. That is what lets an
  older build read a newer file (it restores the sessions and drops what it cannot carry — and
  writes the file back without those lines on its next save, so a downgrade loses contexts, splits,
  slots and layouts, not sessions; a build before P4 reads an `L`-carrying file and restores the
  split left/right, unswapped) and a newer build read an older one (a file from before P3 has no
  `C` or `K`, one from before P4 no `L`, and each restores exactly as it did). Nothing migrates in
  either direction.
- **A malformed `S` line still counts.** `C`, `P`, `L`, `K` and `D` index sessions by *position* among
  the `S` lines, so a session line the reader could not parse shifts every index after it. Rather
  than hang a context, a split, a layout or a slot on the wrong session, each of those sets is
  refused **wholesale** when the number of `S` lines differs from the number that parsed, with one
  `logWarn` naming both counts (`state: 2 session line(s) but 1 parsed - refusing 1 context line(s)
  rather than attaching them to the wrong sessions`). Every parseable session still restores.
- **An `L` line needs its pair.** The layout is applied onto the split the matching `P` line
  rebuilds; an `L` whose owner has no `P` line (`state: layout line for session index 0 has no split
  (P) line to describe - dropped`), or whose split failed to start (`restore: layout for session 'x'
  dropped - its split was not restored`), is dropped and named. A bad `axis` word or `order` digit
  loses that one field to its default (`vertical` / `0`), named in the log, never the line.
- **An index past the `S` list** (a hand-shortened file) drops that one line, named in the log; the
  sessions it does not name are untouched.
- **A loaded context goes through the verb's own rules** — trimmed, not blank, no control character,
  at most 200 characters. One that fails is dropped on load with one `logWarn` naming the session
  and the refusal (`restore: context for session 'x' dropped - session context: control character
  U+0001 at offset 3 …`); the session restores without it and nothing is drawn.
- **A `K` slot lands on the session the restore creates**: `pane0` on the session, `pane1` on the
  split the matching `P` line rebuilds. When that split did not come back — the split failed to
  start, or the `K` line names a split the file has no `P` line for (a hand-edited or
  downgrade-written file) — the `pane1` slot has no pane to belong to and is dropped with a
  `logWarn` naming the session. (A `P` set refused by the count guard takes the `K` set with it —
  the same comparison — so that case never reaches the per-session drop.) A session whose app failed to start keeps its `pane0` slot the way it
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
control character in a `C` line, a `C`/`P`/`L`/`K` count mismatch, a stray index, a pre-P3 file, an
`L` with a bad axis word or order, an `L` without its `P`, a default split writing no `L`, a
truncated write, a `.bak` fallback, a future line type) and restarts a horizontal and a swapped
split, gracefully and killed; `test/control-honesty.ps1` reads the `C` and `K` lines back after
each verb.
