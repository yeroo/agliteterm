# The control API, as agliteterm answers it

agliteterm is scripted through a local named pipe speaking newline-delimited JSON, in the
`agwintermctl` dialect: 65 verbs covering sessions, workspaces, windows, configuration, the sidebar
and the tree. The shared subset is canonical in agwinterm
([`tests/conformance/control-api.json`](https://github.com/yeroo/agwinterm/blob/main/tests/conformance/control-api.json)),
mirrored here as `test/control-api.json` and compared on every build. This page records what lite
answers, verb family by verb family, and every place it deliberately differs from the full app.

Related pages: [launching a session command](session-commands.md), [configuration](configuration.md),
[commands, installers and agent lifecycle](agent-integration.md),
[workspace attention](workspace-attention.md), [the state file](state-file.md).

## Reaching an instance

- Every window is its own process with its own pipe (`--pipe <name>`); all of them share one
  pty-host. `agwintermctl window new/list/select/...` drives the windows.
- `agwintermctl --pipe agliteterm tree` addresses the default instance, which also answers on the
  old name `agwinterm-lite`.
- Shells get the `AGWINTERM_*` environment, so a bare `agwintermctl` inside a pane reaches the
  window it runs in, and the agent skill and status hooks work unchanged.

## Read-only probes

Three probes answer what an agent otherwise has to guess:

- `agwintermctl surface cursor` reports a pane's caret **column** as a bare integer, so an agent can
  tell an empty composer from a draft before typing into another agent's. A *different* column
  proves a draft; an equal one does not prove emptiness — a draft exactly one wrap width long parks
  the caret where it started, so back a match with `session text`. After a print into the last
  column it equals the pane width; clamp before indexing.
- Every `tree` node carries `statusChangedAt`, epoch seconds of the last status **write**, restamped
  on every write including a re-assert of the same status, so a stale `"active"` shows its age.
- `ping` names the running build (`agliteterm <version>`), which is what `agwintermctl version`
  reports as the app.

## Typing text

- `session type --stdin` takes the text from standard input as bytes — how quotes, newlines, runs
  of spaces and a leading `--` are sent, none of which survives the argv path. Exactly one trailing
  newline is dropped; invalid UTF-8 is refused before anything is sent. The flag lives in the shared
  `agwintermctl`; lite's server side is unchanged.
- There is no `quick type`: the quick terminal is a hidden session, typed into as
  `session type --window quick` while visible or `session type --target <its id>` (the id arrives as
  a `session`/`created` event after `quick on`).
- `session type` and `session paste` always answer well inside `agwintermctl`'s 30 s reply
  deadline (#110). They wait at most 5 s for the pane's input. If another type/paste still holds it,
  or a write whose cancellation has not resolved keeps it reserved, the call refuses with
  `input to this pane is busy or reserved; nothing typed` (or `nothing pasted`), and no byte is
  written. The text then goes out in chunks of at most 4096 bytes, never split inside a UTF-8
  character, under one 15 s deadline for the whole text. `typed` / `pasted` mean every byte was
  written, as before. A write that stops early refuses with `N of M bytes written`, then the K-byte
  chunk at offset N, which was cancelled or failed and **may have been partly delivered**, then the
  remaining bytes, which were not written. So a caller that retries the whole text repeats N bytes,
  plus up to K. Only `session type` can resume from offset N: its counts are over the text as sent,
  where the only change is `\n` becoming `\r`, byte for byte, and a resume may still repeat up to K
  bytes. For `session paste`, the counts include `ESC[200~` and are over the normalized text, where
  CRLF becomes CR, and a clipboard paste's text is never seen by the caller. So those counts say how
  far the paste got, but they are not an offset into the caller's text. If a chunk's cancellation
  has not resolved within 1 s, the reply says it is still in flight and may still arrive. The pane's
  input then stays reserved, so human keys and other API input are refused, until that write
  resolves. An `input` event is emitted when that happens.
- A bracketed `session paste` writes `ESC[200~` and `ESC[201~` as chunks of their own. If the
  paste stops after the opening marker, lite sends a separate `ESC[201~` (bounded to 500 ms) so the
  application is not left inside a paste, and the reply says whether that worked. That separate
  close is reported on its own and is not counted among the remaining bytes. If only the closing
  marker was left when the deadline passed and the separate close then succeeds, every byte went,
  and the reply is `pasted`. Lite does not send a separate close:
  - when the opening marker itself was stopped (whether the paste was opened is unknown);
  - when a body chunk is still in flight (the reply says the paste is left open);
  - when the stopped chunk was the closing marker itself. If that chunk is still in flight, the reply
    says so. Do not close the paste yourself: that marker may still arrive.
- `session write` is display-only. What it paints is not durable: the shell's next repaint, and the
  full repaint the pty-host does on every resize (a window resize, `session split`, a split-ratio
  change, `session split close`), paints over it, and it does not survive into scrollback.

## A reply of `ok` did what was asked

Parity batch P2 made every success reply mean what it says:

- `session overlay open <cmd> --size-percent N` is validated as 1..100 and refused otherwise with
  nothing opened. The reply carries the percentage **in effect**: a popup cannot be under 30x8
  cells, so a small window raises a low one. A window that cannot be measured at all — minimised, or
  a client under 30x8 cells — is told what it got and why, with no number.
- `session overlay resize` moves the popup and refuses when none is open.
- `sidebar width [N]` reads or sets the divider (90..900 px, and never so wide that the terminal
  drops under 20 columns) and answers the width **in effect**. An unknown sidebar op is refused
  instead of toggling.
- A bare `session new` lands in the **caller's** workspace, not the active one, and `--workspace`
  beside `--workspace-name` is refused.
- `window select` says `selected` only when the window really came to the front.
- No verb steals the foreground from the app you are typing in: a popup raises only when agliteterm
  already holds it, and flashes the taskbar button otherwise.

## Session context

`session context <text> | --clear` (P3) keeps one line of free text per session.

- The text is trimmed. Blank text, a control character (the refusal names its offset), more than 200
  characters, and text beside `--clear` are refused with the full app's wording, and the old value
  is kept.
- It is shown **dimmed after the name** in the sidebar row and read back as `context` from
  `tree --json`.
- It is kept across a restart (a `C` line in the state file) and an undo-close; a rename leaves it
  alone.
- A split, quick, scratch or overlay pane (no row, no session line in the state file) is refused.

## Restore capture

`restore capture [--target ID]` (P3) captures the foreground command of every real pane, or of the
one named, into a per-pane slot.

- The captured command is the newest child of the pane's shell that is not a shell or prompt helper
  (the full app's default denylist, fixed in lite).
- It **saves before it answers when at least one slot is replaced**, and reports per pane — `null`
  when the shell had nothing but a shell running. Null is written too, so a fresh capture replaces
  an older checkpoint. A call where nothing landed (every snapshotted target closed during the query)
  is a no-op without a save or refresh.
- The slots read back as `capturedCommands` from `tree --json`, keyed by pane id, and persist as a
  `K` line (lossless `K2` for tabs and newlines).
- Its `replayOnRestore` reports the **default-off `restore-commands` setting**. With that opt-in,
  fresh restored shells can replay K; bindings (`B`) win over pins (`R`), which win over K. Adopted,
  closed, exited and readonly panes skip replay.
- An unknown, empty or cover-pane target, or a process query that did not run, is refused with
  nothing written for anyone. A save that did not land is refused too, but AFTER the slots were
  replaced in memory (the reply says so, `tree --json` shows them): that save did not put the
  checkpoint on disk; a later one may.
- **With `restore-commands` on, the close captures too**: the quit fills every real pane's slot from
  what is running then, while the shells are still alive, before its final save — so a restart
  replays what the panes were doing, not whatever a hand-run capture froze hours earlier. With the
  opt-in off the close captures nothing.

## Splits

Parity batch P4 gives a split its full shape, in agterm's words: `vertical` = left/right panes (the
default), `horizontal` = top/bottom. The axis names the arrangement, never the divider.

- **To get a pane, use `session split on`.** The bare form is a toggle: on a session that is already
  split it closes the split and answers the survivor's id — the session's own shell — so a script
  that asks twice ends up addressing the pane it runs in. `on` answers slot 1's id every time.
- `session split [on|off|toggle] [--axis ..] [--target ID]` **answers a pane id** (a bare string)
  whichever way it went: `on` the right/bottom pane's, also when already split; `off` the survivor's,
  also when already single. It honours its target (a session, either pane, a prefix, a name; a cover
  is refused with nothing split; a session off-screen is split without moving focus), and re-orients
  a split session live.
- `session split close --target ID` closes **either** side — which `off` cannot, since it takes
  slot 1 — and answers the survivor's id. A one-pane session is refused, naming `session close`.
- `session swap` exchanges the two slots and nothing else: the focus follows its pane, the axis
  stays, **no id moves**. It answers the tree's split block.
- `session focus [primary|split|left|right|top|bottom|other]` moves between the panes; the pair that
  does not exist on the axis is refused, naming it.
- A split session's `tree` node carries the block — `paneCount`, `paneIds` in slot order,
  `focusedPane`, `axis` — and a single one carries none of it, except that a promoted session's node
  carries `paneIds` alone (`[<its shell's id>]`, the one single session whose pane id is not its
  `id`). Every structural change emits `tree`.
- `session resize --split-ratio R` or `--grow-left/right/top/bottom N` moves the active split's divider —
  the split on screen; it does not take `--target`.
  Wrong-axis or malformed growth refuses; ratios clamp to 0.05..0.95 and persist.

**The session-id rule.** A session id names the session's own shell while it exists. Whenever that
shell is the one that closes — `split close` on it, the close chord on it, `split off` / `toggle` /
the Split key or menu row after a swap (slot 1 is the owner then), or its process exiting — the
survivor **becomes the session**: same id, name, flag, context and sidebar row, its own pane id
kept. A split side whose shell exits collapses to the survivor on its own. After a kill-and-relaunch
a promoted session is adopted by its shell's id and comes back under it (the file records shells,
not promotions).

The close chord and *File ▸ Close Pane / Session* close the focused **pane** on a split session; the
sidebar row's *Close Session* closes the whole session.

## Overlays

Parity batch P5 gives a session three overlay slots: the session-wide one — the popup, unchanged —
and one per pane.

- `session overlay open <cmd> --pane left|right` runs the command in a hidden session drawn in that
  pane's box instead of its shell (`left` = slot 0, `right` = slot 1, whatever the axis; a one-pane
  session takes `left`) and **answers the overlay's id**, a session id the program inside holds as
  its `AGWINTERM_SESSION_ID`.
- The sibling pane keeps rendering and taking input. The overlay is the covered pane's **surface**:
  keys and the mouse reach it, and the pane's own id reaches the shell underneath. On
  `session overlay`, the overlay's id names its slot (see [Targets](#targets)).
- Refused with nothing opened: a word that is not `left` / `right`; `--pane right` on one pane
  (`pane not visible`); a slot already holding one (`pane overlay already open` — no silent
  replace); a `--target` naming the other side; and `--size-percent` / `resize` with `--pane` (a
  pane overlay is always full-box; the CLI refuses first, the server for a raw client).
- `close --pane X` shows the shell again (`closed`, or `no overlay` when empty).
- `result --pane X` is that slot's `exit N` — the command's status as PowerShell reports it, carried
  in an FTCS mark the overlay's own command line emits. It is refused `overlay still running` while
  the overlay is up and `no overlay result` before anything completed there. The bare `result` is
  the window-wide last popup exit.
- `copy` and `text [--all | --lines N]` answer `{text}` on either slot — the selection made inside
  the overlay (the clipboard untouched) and its buffer — refused `no overlay` / `no selection` when
  absent. The popup supports drag selection and `selection all`; `copy` reads its selected text
  without changing the clipboard.
- The tree node carries `paneOverlays` (`["left"]`, `["right"]`, both, in slot order; absent when
  empty). The slot moves with its pane on a swap and dies with it (`split close`, `split off`, the
  shell exiting, `session close`). Nothing of it is persisted.
- The close chord closes a focused popup first, then the focused pane's overlay.

`session text` takes the same `--lines N` (the last N lines; `0` the screen; a non-number refused
instead of dropped) and `--all`. `--all` is lite's bare form; the full app's bare form is the screen
only, a recorded difference. The pair together is refused.

`session text --styles` returns `{cols,rows,cursor}` instead of a string. Each row has its
screen-relative `row` (negative for scrollback) and `runs` with grid-cell `col`/`width`, `text`,
six flags (`faint`, `bold`, `italic`, `underline`, `inverse`, `strike`) and `fg`/`bg` specs
(`default`, `idx:N`, or `#rrggbb`). A wide glyph occupies two cells but contributes one character.
It selects the same rows as lite's plain text, including `--all` and `--lines`, and trims trailing
ASCII spaces on each row. Blank rows at the end are omitted; an entirely blank buffer has `rows:[]`.
`session overlay text --styles` is refused; use `session text --styles --target <overlay-id>`.

## Targets

- `--target active` on a **session** verb (`select`, `flag`, `rename`, `duplicate`, …) is the session
  under the focused pane.
- On a **pane** verb (`close`, the split verbs, `restore capture`) it is the pane's shell.
- On a **surface** verb (`session type` / `write` / `output` / `text` / `copy` / `paste`,
  `surface cursor`, `session overlay`, `selection all` / `copy` / `clear` / `finalize`) it is the
  overlay.
- On `session overlay` (`close`, `result`, `copy`, `text`), `--target <overlay id>` without `--pane`
  names the slot that overlay occupies.
- An overlay's id reaches it on the surface verbs only, and is refused as a cover by every other verb
  (`close`, `select`, `flag`, `rename`, `duplicate`, …). `flag clear` alone takes no target and
  unflags every session.

## Selection

- `selection all` selects history and screen (only the app's screen on the alt screen).
- `selection copy` writes the clipboard and clears the highlight. `copied N chars` counts UTF-8 bytes
  of the text `session copy` returns, with CRLF between rows and trailing spaces trimmed. The
  clipboard write is posted to the UI thread; allow its next message before reading it.
- `selection clear` clears the highlight.
- `selection finalize` is the release-copy testing hook: it copies and keeps the highlight when
  copy-on-select is on (the default); when off it answers `finalized (copy-on-select off)` without
  writing.
- A blank Copy answers `nothing to copy`, clears the highlight and leaves the clipboard alone; a blank
  Finalize keeps the highlight. Copy and Finalize can refuse a failed UI enqueue with
  `the clipboard write could not be queued; selection unchanged`.
- Popup terminals (overlay, quick and scratch) support selection too.

## Driving a pane

- `session readonly on|off|toggle|state|get [--target ID]` blocks human keys, paste and reporting
  mouse events. API typing and writing and terminal replies still work; API paste explicitly
  refuses. The flag is per surface and resets on restart. The status bar shows READ-ONLY; the
  Edit/palette toggle has an unbound `Key_ReadOnly` binding.
- `session paste` refuses an observed exited or readonly target before clipboard access.
  Unterminated or odd-sized UTF-16 clipboard blocks, and blocks larger than 16 MiB, are unavailable.
  Empty or unavailable text returns `nothing to paste`; `pasted` means input was handed off without a
  synchronous error, not proof of application execution. Partial or failed writes refuse and say how
  far they got (see Typing text); do not retry blindly.
- `session restore <command>|none --target PANE` pins a command for a fresh restored shell.
  `session bind <agent-command>|none --target PANE` supplies a binding instead (default `claude`).
  Both save before success. Replay waits 2500 ms, uses current values, and skips adopted shells; the
  delay does not prove shell readiness. Captured commands are separate and replay only with the
  explicit `restore-commands` opt-in; B and R take precedence.
- `session switch begin|advance|advance-back|commit|cancel` walks a snapshot of session recency.
  Ordinary next/previous keys keep tree order.
- `session search QUERY [--next|--prev|--close]` searches the active surface, even when a valid
  target is supplied. Unicode matches map to cells, including wide glyphs. Cyan frames mark the
  current match, amber frames the others, with FIND in the status bar. Counts are as of the last
  search call; changed rows suppress stale highlights until another call. There is no find bar or
  Ctrl+F. History is never scrolled into on the alt screen.
- `session background` is unavailable: lite draws no images.

The manual checks behind this section are in [qa/driving.md](../qa/driving.md).
