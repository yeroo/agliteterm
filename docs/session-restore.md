# Session restore

agliteterm saves its workspaces and sessions whenever the tree changes and on exit, and rebuilds them
on the next launch (`--no-restore` starts empty instead). Everything about that is on disk and
readable. The file format, line by line, is in [the state file](state-file.md).

## One state file per instance

`%LOCALAPPDATA%\agliteterm\sessions.tsv` for the default instance, `sessions-<instance>.tsv` for a
named one. **Because every window is its own process, each window restores only its own sessions**:
sessions you created in `--pipe work` come back in `--pipe work`, never in the default window. That
is the mundane reading of "my sessions are gone": right sessions, wrong window.

The format is tab-separated UTF-8 text with a `V1` header and one record per line. It grows by
*adding* line types, so a file written by an older build still restores, and a file from a **newer**
build is read for the lines this one knows rather than thrown away (a build before P4 restores a split
with a layout line left/right, unswapped — the layout is lost, never the split).

## What is saved

- The visible sessions, each with its *live* working directory (read from the shell process, so it
  follows you as you `cd`), its context and its captured command.
- Each session's split shell (its own app, cwd and slot) with its layout — top/bottom or left/right,
  and which side the session's own shell sits on after a `session swap` — so the split comes back
  with its owner the way it was.
- The quick, scratch and overlay covers — the three popups and a pane overlay alike — are hidden and
  are not persisted.

## Writes are atomic, and keep one generation

The save writes `sessions.tsv.tmp`, rotates the current file to **`sessions.tsv.bak`**, then renames
the temp over the target, so a crash or a full disk mid-write cannot leave a truncated file where a
good one was. A zero-session save is *refused* over a populated file (and says so in the log); the one
legitimate empty is you closing the last session, which also deletes the `.bak` so what you just
closed does not come back.

## Restore order

`sessions.tsv` → `.bak` if the primary is missing, empty, or parses to zero sessions → a fresh window.

If the pty-host still holds the shells — agliteterm was killed or the machine was shut down rather
than closed — those shells are **still running** and are adopted live instead of relaunched. An
adopted shell keeps everything it was running, and agliteterm asks it to redraw, so the **screen comes
back**, but the **scrollback does not**: it re-attaches to the live process with a fresh emulator, so
only what is on screen is repainted. A shell that has already exited, or one another window is
currently driving, is not adopted; it is relaunched (or left to its owner) instead.

## A spec that will not start on this machine

A profile whose exe only exists on your other PC, or a cwd on an unmounted drive, stays in the tree
as a `(failed to start)` entry with a note in its pane rather than silently vanishing. Its name,
workspace, cwd and args are kept and re-saved, so it starts normally again on the machine that has the
app. Scripts can spot one without reading the log: `agwintermctl tree --json` reports `"failed"` and
`"exited"` per session.

## Recovering by hand

`--no-restore` starts empty, and the next save publishes *that* over `sessions.tsv`, but the
generation you wanted survives as `sessions.tsv.bak`.

1. **Copy the `.bak` somewhere safe first.** Only one generation is kept, so the next save of the
   window you are looking at overwrites it in turn.
2. Close agliteterm.
3. Copy your saved file over `sessions.tsv`, and relaunch.

`agliteterm --diagnose` prints both files with their sizes (and the primary's contents), so you can
tell which one holds your sessions before you copy anything.

*File ▸ Restart everything* relaunches the **same** instance: it carries this window's `--pipe <name>`
over, so it comes back reading the same state file. `--diagnose` prints the exact command line it
would use.

## Test cover

Every one of those branches names itself in `agliteterm.log`, and `test/restore-matrix.ps1` drives
the whole matrix — kill vs. graceful close, two windows at once, interrupted writes, `.bak` fallback,
bogus apps, old and future file formats — as regression cover.
