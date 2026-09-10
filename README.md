<div align="center">

<img src="docs/agliteterm-icon.png" width="96" alt="agliteterm icon" />

# agliteterm

**A tiny native Windows terminal for AI coding agents.**

Part of the [agwinterm](https://github.com/yeroo/agwinterm) family: same Rust emulator core, same
pty-host, same control API — a fraction of the footprint. One small C++ exe, **no .NET runtime**,
real native Win32 controls.

**Feature parity with agwinterm is the goal, not a cut-down build.** What is still missing (and the
few places this one is ahead) is tracked in
[agwinterm/docs/lite-parity.md](https://github.com/yeroo/agwinterm/blob/main/docs/lite-parity.md),
kept there because the control-API contract is canonical in that repo. Both products' standing
against umputun's agterm is in
[agterm-parity.md](https://github.com/yeroo/agwinterm/blob/main/docs/agterm-parity.md).

[![CI](https://github.com/yeroo/agliteterm/actions/workflows/ci.yml/badge.svg)](https://github.com/yeroo/agliteterm/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/yeroo/agliteterm/badge)](https://scorecard.dev/viewer/?uri=github.com/yeroo/agliteterm)
[![Release](https://img.shields.io/github/v/release/yeroo/agliteterm?sort=semver)](https://github.com/yeroo/agliteterm/releases)
[![Downloads](https://img.shields.io/github/downloads/yeroo/agliteterm/total.svg)](https://github.com/yeroo/agliteterm/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<img src="docs/img/screenshot.png" width="820" alt="agliteterm running Claude Code, with the working session marked in the sidebar" />

</div>

---

> **Was `agwinterm-lite`.** An existing agwinterm-lite install is handed over by its own updater
> (agwinterm 0.17.4 points at this feed). agliteterm installs **alongside** rather than replacing it
> and adopts your sessions, settings and fonts on first run, so nothing is lost and you can go back.
> Scripts using `--pipe agwinterm-lite` keep working — the default instance answers on both names —
> and the `AGWINTERM_*` session variables are unchanged.

**agliteterm** is a minimal Windows terminal for old or low-RAM machines: a single small
C++ exe (Win32/WTL, no .NET) over the same Rust emulator core and pty-host that
[agwinterm](https://github.com/yeroo/agwinterm) uses. It trades custom-drawn chrome for **real
native controls** — menu bar, toolbar, TreeView sidebar, status bar — in the classic Windows look.

- **Themes**: Dark / Light / Classic / Auto (follows Windows) from *File → Properties*. Dark
  covers everything — menus, toolbar, sidebar, dialogs, scrollbars, title bar. **Classic** keeps
  the authentic raised-3D, pre-theme look.
- **Agent workflow**: per-session agent status (bold = blocked, italic = working), an
  **attention bell** that lights amber and jumps to the next blocked session, **flagged
  sessions** with a flagged-only view, **unread badges** (commands finished while a session was
  off-screen), workspace focus, sidebar **drag & drop**.
- **Workspace attention**: opt-in keyboard broadcast, clickable notifications, fixed-strike live
  dashboard previews, workspace reordering and explicit saved-state clearing. See
  [behavior and safety boundaries](docs/workspace-attention.md).
- **Terminals**: workspaces + sessions with restore, a 2-pane split (left/right or top/bottom,
  either side closable, the two swappable), quick / scratch / overlay
  popup terminals, a **pane overlay** — a command drawn over ONE pane's box, badged `overlay`,
  while the other pane stays interactive (`session overlay open <cmd> --pane left|right`), font catalog (incl. bundled Cozette, Tamzen, Terminus, Spleen, UNSCII &
  GNU Unifont bitmap fonts) — face and size are chosen once in Properties; there is deliberately
  **no zoom**, because a raster face only exists at the strike sizes its pack ships,
  MS-DOS/EGA palette, cmd.exe-style Properties dialog, fully rebindable keys (Ctrl+Shift+P opens
  the palette, Ctrl+Shift+M toggles mark mode, Ctrl+Shift+A selects all; other actions start unbound).
  The two pane-focus rows are by **slot** — *Focus Left /
  Top Pane* is slot 0 and *Focus Right / Bottom Pane* slot 1, whichever shell a `session swap` put
  there, and the same two rows serve both axes. The **sidebar text size** is set separately
  (*Properties → Sidebar text*), because wanting a bigger session list is not wanting a
  bigger terminal.
- **Clipboard**: select with the mouse and it is copied on release
  (double/triple-click selects a word/line; dragging past an edge auto-scrolls). Mark mode starts
  at the caret: arrows and Home/End extend, Enter or Ctrl+C copies and exits while keeping the
  highlight, Esc or the configured mark chord clears and exits. Select All only highlights.
  These work in panes and overlay/quick/scratch popups. The alt screen stays pinned to its own
  rows: wheel, drag and mark mode cannot reach main-screen history. **Ctrl+C copies a selection**
  and otherwise interrupts the shell (Ctrl+Shift+C always copies); **right-click pastes**
  even while a full-screen app is grabbing the mouse — a TUI like Claude Code holds mouse mode on
  for its whole run, which is exactly when pasting matters. A program can drive the clipboard
  itself with **OSC 52**, and terminal queries get answered. Both bindings are on by default; the
  registry escape hatch is `RightClickPaste` / `CopyOnCtrlC` (DWORD `0`) under
  `HKCU\Software\agliteterm`.
- **Selection API**: `selection all` selects history and screen (only the app's screen on the alt
  screen); `selection copy` writes the clipboard and clears the highlight; `selection clear`
  clears it. `copied N chars` counts UTF-8 bytes of the text `session copy` returns, with CRLF
  between rows and trailing spaces trimmed. The clipboard write is posted to the UI thread;
  allow its next message before reading it. `selection finalize` is the release-copy testing
  hook: it copies and keeps the highlight when copy-on-select is on (the default); when off it
  answers `finalized (copy-on-select off)` without writing. Popup terminals
  (overlay, quick and scratch) support selection too.
  Blank Copy answers `nothing to copy`, clears the highlight, and leaves the clipboard alone;
  blank Finalize keeps the highlight. Copy and Finalize can refuse a failed UI enqueue with
  `the clipboard write could not be queued; selection unchanged`.
- **Scriptable**: the same newline-JSON control pipe, speaking the `agwintermctl` dialect —
  65 verbs covering sessions, workspaces, windows, configuration, the sidebar and the tree (`agwintermctl --pipe
  agliteterm tree`). Shells get `AGWINTERM_*` env, so hooks and the agent skill work. Three
  read-only probes answer what an agent otherwise has to guess: `agwintermctl surface cursor`
  reports a pane's caret **column** as a bare integer, so an agent can tell an empty composer from
  a draft before typing into another agent's (a *different* column proves a draft; an equal one
  does not prove emptiness — a draft exactly one wrap width long parks the caret where it started,
  so back a match with `session text`; after a print into the last column it equals the pane
  width — clamp before indexing); every `tree` node carries `statusChangedAt`, epoch seconds
  of the last status **write**, restamped on every write including a re-assert of the same status,
  so a stale `"active"` shows its age; and `ping` names the running build (`agliteterm
  <version>`), which is what `agwintermctl version` reports as the app. `session type --stdin`
  takes the text from standard input as bytes — how quotes, newlines, runs of spaces and a
  leading `--` are sent, none of which survives the argv path (exactly one trailing newline is
  dropped; invalid UTF-8 is refused before anything is sent). The flag lives in the shared
  `agwintermctl`; lite's server side is unchanged. There is no `quick type`: the quick terminal
  is a hidden session, typed into as `session type --window quick` while visible or
  `session type --target <its id>` (the id arrives as a
  `session`/`created` event after `quick on`). And a call that answers `ok` did what was asked
  (parity batch P2): `session overlay open <cmd> --size-percent N` is validated as 1..100 and
  refused otherwise with nothing opened, and the reply carries the percentage **in effect** (a popup
  cannot be under 30x8 cells, so a small window raises a low one; a window that cannot be measured
  at all — minimised, or a client under 30x8 cells — is told what it got and why, with no number);
  `resize` moves the popup and refuses when none is open;
  `sidebar width [N]` reads or sets the divider (90..900 px, and never so wide that the terminal
  drops under 20 columns) and answers the width **in effect**, while an unknown sidebar op is
  refused instead of toggling; a bare `session new` lands in the **caller's** workspace, not the
  active one, and `--workspace` beside `--workspace-name` is refused; `window select` says
  `selected` only when the window really came to the front. No verb steals the foreground from
  the app you are typing in — a popup raises only when agliteterm already holds it, and flashes
  the taskbar button otherwise. Parity batch P3 adds the two persistence verbs. `session context
  <text> | --clear` keeps one line of free text per session — trimmed; blank, a control character
  (naming its offset), more than 200 characters and text beside `--clear` refused with the full
  app's wording and the old value kept — shown **dimmed after the name** in the sidebar row, read
  back as `context` from `tree --json`, and kept across a restart (a `C` line in the state file)
  and an undo-close; a rename leaves it alone, and a split, quick, scratch or overlay pane (no
  row, no session line in the state file) is refused. `restore capture [--target ID]` captures the foreground command
  of every real pane, or of the one named, into a per-pane slot (the newest child of the pane's
  shell that is not a shell or prompt helper: the full app's default denylist, fixed in lite),
  **saves before it answers when at least one slot is replaced**, and reports per pane — `null` when the shell had nothing but a
  shell running, and null is written too, so a fresh capture replaces an older checkpoint. The
  zero-landed call (all snapshotted targets closed during the query) is a no-op without a save or refresh. The
  slots read back as `capturedCommands` from `tree --json`, keyed by pane id, and persist as a
  `K` line (lossless `K2` for tabs/newlines). Its `replayOnRestore` reports the **default-off `restore-commands` setting**. With opt-in,
  fresh restored shells can replay K; bindings B win over pins R, which win over K. Adopted, closed,
  exited and readonly panes skip replay. An unknown, empty or cover-pane target, or a process query
  that did not run, is refused with nothing written for anyone; a save that did not land is
  refused too, but AFTER the slots were replaced in memory (the reply says so, `tree --json` shows
  them) — that save did not put the checkpoint on disk; a later one may. Parity batch P4 gives a split its
  full shape, in agterm's words: `vertical` = left/right panes (the default), `horizontal` =
  top/bottom — the axis names the arrangement, never the divider. `session split [on|off|toggle]
  [--axis ..] [--target ID]` **answers a pane id** (a bare string) whichever way it went — `on`
  the right/bottom pane's, also when already split; `off` the survivor's, also when already
  single — honours its target (a session, either pane, a prefix, a name; a cover refused with
  nothing split; a session off-screen split without moving focus), and re-orients a split session
  live. `session split close --target ID` closes **either** side — which `off` cannot (it takes slot 1), and which no verb or key could before P4 — and answers the survivor's id; a one-pane session is refused naming `session close`.
  `session swap` exchanges the two slots and nothing else — the focus follows its pane, the axis
  stays, **no id moves** — and answers the tree's split block. `session focus
  [primary|split|left|right|top|bottom|other]` moves between the panes, the pair that does not
  exist on the axis refused naming it. A split session's `tree` node carries the block —
  `paneCount`, `paneIds` in slot order, `focusedPane`, `axis` — and a single one carries none of
  it, except that a promoted session's node carries `paneIds` alone (`[<its shell's id>]` — the
  one single session whose pane id is not its `id`); every structural change emits `tree`. The session-id rule: a session id names the session's
  own shell while it exists; **whenever that shell is the one that closes** — whatever closed it:
  `split close` on it, the close chord on it, `split off` / `toggle` / the Split key or menu row
  after a swap (slot 1 is the owner then), or its process exiting — the survivor **becomes the
  session** — same id, name, flag, context, sidebar row, its own pane id kept — and a split side
  whose shell exits collapses to the survivor on its own. After a kill-and-relaunch a promoted
  session is adopted by its shell's id and comes back under it (the file records shells, not
  promotions). The close chord and File ▸ Close Pane / Session close the focused **pane** on a split
  session; the sidebar row's Close Session closes the whole session. Parity batch P5 gives a
  session three overlay slots: the session-wide one — the popup, unchanged — and one per pane.
  `session overlay open <cmd> --pane left|right` runs the command in a hidden session drawn in
  that pane's box instead of its shell (`left` = slot 0, `right` = slot 1, whatever the axis; a
  one-pane session takes `left`) and **answers the overlay's id**, a session id the program inside
  holds as its `AGWINTERM_SESSION_ID`; the sibling pane keeps rendering and taking input, and the
  overlay is the covered pane's **surface** — keys and the mouse reach it, the pane's own id
  reaches the shell underneath, and on `session overlay` the overlay's id names its slot (the
  `--target` rule is below). Refused with nothing opened: a word that is not `left` /
  `right`, `--pane right` on one pane (`pane not visible`), a slot already holding one (`pane
  overlay already open` — no silent replace), a `--target` naming the other side, and
  `--size-percent` / `resize` with `--pane` (a pane overlay is always full-box; the CLI refuses
  first, the server for a raw client). `close --pane X` shows the shell again (`closed`, or `no
  overlay` when empty); `result --pane X` is that slot's `exit N` — the command's status as
  PowerShell reports it, carried in an FTCS mark the overlay's own command line emits — refused
  `overlay still running` while it is up and `no overlay result` before anything completed there;
  the bare `result` is the window-wide last popup exit. `copy` and `text [--all | --lines N]`
  answer `{text}` on either slot — the selection made inside the overlay (the clipboard
  untouched) and its buffer — refused `no overlay` / `no selection` when absent. The popup supports
  drag selection and `selection all`; `copy` reads its selected text without changing the clipboard.
  `session text` gains the same `--lines N` (the last N
  lines; `0` the screen; a non-number refused instead of dropped) and `--all` (lite's bare form —
  the full app's bare form is the screen only, a recorded difference); the pair is refused. The
  tree node carries `paneOverlays` (`["left"]`, `["right"]`, both, in slot order; absent when
  empty); the slot moves with its pane on a swap and dies with it (`split close`, `split off`,
  the shell exiting, `session close`); the close chord closes a focused popup first, then the
  focused pane's overlay; `--target active` on a session verb (`select`, `flag`, `rename`,
  `duplicate`, …) is the session under the focused pane, on a pane verb (`close`, the split
  verbs, `restore capture`) the pane's shell, on a surface verb (`session type` / `write` /
  `output` / `text` / `copy` / `paste`, `surface cursor`, `session overlay`,
  `selection all` / `copy` / `clear` / `finalize`) the
  overlay; an overlay's id reaches it on the surface verbs only and is refused as a cover by
  every other verb (`close`, `select`, `flag`, `rename`, `duplicate`, …; `flag clear` alone takes
  no target and unflags every session); nothing of it is persisted.
- **Multi-window**: every window is its own tiny process (`--pipe <name>`), all
  sharing one pty-host; `agwintermctl window new/list/select/...` drives them.
- **CLI**: `-p/--profile`, `-d/--dir`, `--maximized`, `--no-restore`, `--pipe` — the full app's
  flag names — plus `--diagnose` (see below).
- **Explains itself**: it keeps a small always-on log of its own decisions — session saves and
  restores (with counts, byte totals, and the exact error when a write fails), focus handoffs, and
  font/pack resolution — at `%LOCALAPPDATA%\agliteterm\agliteterm.log` (`agliteterm-<instance>.log` for named
  instances), rotating at ~1 MB into `.log.old`. It records what the client *did*, never terminal output,
  pasted text, or your command lines, so it's safe to attach to an issue.


## Install

```powershell
winget install yeroo.agliteterm
choco install agliteterm
```

Or grab **`agliteterm-setup-<version>.exe`** from
[Releases](https://github.com/yeroo/agliteterm/releases) — per-user, no admin. It self-updates from
that feed (*Help → Check for Updates*), verifying the SHA-256 the release API publishes for the
asset before applying anything.

**No installer at all**: `agliteterm-portable-<version>-win-x64.zip` is the same payload unzipped
where you like. Settings still live in `%LOCALAPPDATA%\agliteterm`, so a portable copy and an
installed one share their sessions. (This is what the Chocolatey package installs — the setup is
per-user and Chocolatey runs elevated, which would put agliteterm in the administrator's profile.)

Package-manager versions are deliberately sparser than releases: winget and Chocolatey are
human-moderated, so only **checkpoint** versions (`x.y.9`, `x.y.18`, ...) are submitted. Everything
between them ships here and through the in-app updater.

Every release carries a [Sigstore build-provenance attestation](https://github.com/yeroo/agliteterm/attestations):

```
gh attestation verify agliteterm-setup-<version>.exe --repo yeroo/agliteterm
```

## Driving a pane

- `session readonly on|off|toggle|state|get [--target ID]` blocks human keys, paste and reporting
  mouse events. API typing/writing and terminal replies still work; API paste explicitly refuses.
- `session paste` refuses an observed exited/readonly target before clipboard access.
  Unterminated or odd-sized UTF-16 clipboard blocks, and blocks larger than 16 MiB, are unavailable.
  Empty or unavailable text returns `nothing to paste`; `pasted` means input was handed off without a
  synchronous error, not proof of application execution. Partial/failed writes refuse; do not retry blindly.
  The flag is per surface and resets on restart. Status shows READ-ONLY; the Edit/palette toggle
  has an unbound `Key_ReadOnly` binding.
- `session restore <command>|none --target PANE` pins a command for a fresh restored shell.
  `session bind <agent-command>|none --target PANE` supplies a binding instead (default `claude`).
  Both save before success. Replay waits 2500 ms, uses current values, and skips adopted shells.
  This delay does not prove shell readiness. Captured commands are separate and replay only with
  P10b's explicit `restore-commands` opt-in; B/R take precedence.
- `session resize --split-ratio R` or `--grow-left/right/top/bottom N` moves the active split's
  divider. Wrong-axis/malformed growth refuses; ratios clamp to 0.05..0.95 and persist.
- `session switch begin|advance|advance-back|commit|cancel` walks a snapshot of session recency.
  Ordinary next/previous keys retain tree order.
- `session search QUERY [--next|--prev|--close]` searches the active surface, even when a valid
  target is supplied. Unicode matches map to cells, including wide glyphs. Cyan frames mark the
  current match, amber frames the others, with FIND in the status bar. Counts are as of the last
  search call; changed rows suppress stale highlights until another call. No find bar/Ctrl+F.
  History is never scrolled into on the alt screen.

`session background` remains unavailable: lite draws no images. See [driving checks](qa/driving.md).

## Configuration (P10a)

`config list` reports supported keys and current values; `config get KEY` reads one;
`config set KEY VALUE` saves only that registry value under `HKCU\Software\agliteterm` and
applies it to this instance. Other running instances are not changed; future launches read the
saved values. Unknown keys and invalid values refuse without changing settings. Writes also
refuse while a modal dialog is open/queued, protecting its unsaved edits. A timed-out request
already executing reports an unknown outcome: read back before retrying.

| Keys | Values |
| --- | --- |
| theme | auto, dark, light, classic (lite's UI modes, not the full app's theme catalog) |
| custom-colors, dos-palette, show-sidebar, show-toolbar, show-status, flag-view | true/false (also on/off or1/0) |
| right-click-paste, copy-on-ctrl-c, copy-on-select | true/false (also on/off or1/0) |
| foreground, background | #RRGGBB; used when custom-colors is true |
| sidebar-font-size | 0 for system default, or6..24 |
| scrollback-lines | 0..1000000; default5000; new surfaces only, no live eviction; positive caps allow 512 rows of batched-trim slack |

`theme list/set` uses the same four modes. `settings` requests the Properties dialog without
raising the terminal; its reply is `settings open requested`. `keymap reload` reloads registry
bindings: deleted entries return to their default/unbound state, explicit zero stays unbound.
With copy-on-select off, mouse release/finalize leave the clipboard alone; explicit Copy and
mark-mode Enter/Ctrl+C still copy. Scrollback config affects the local replica, not the host's
retained history, and is applied before a new/adopted surface receives bytes.

P10b adds the shell configuration below. Font targeting remains subject to the no-zoom policy.
The shared control conformance floor is unchanged.

### Shell profiles, OMP and captured replay (P10b)

`profiles list` reads the current catalog; `profiles reload` validates
`%LOCALAPPDATA%\agliteterm\profiles.json` and replaces the catalog atomically. A missing file uses
detected shells in memory. Neither operation writes the file; malformed/unreadable reloads refuse
and retain the last good catalog. Startup logs malformed files and falls back to detected shells.

```json
{"default":"Build","profiles":[{"name":"Build","command":"cmd.exe","args":["/k"],"cwd":"C:\\src"}]}
```

The New Session dialog, `--profile NAME` startup switch, and `session new --profile NAME` use exact
names (ASCII-case-insensitive). Unknown/empty names refuse; command+profile is ambiguous and refuses.
An explicit cwd overrides the profile cwd. Running sessions retain their resolved launch spec.
Supported profile fields are name/command/args/cwd. Nonempty env/icon, elevation and unknown fields
refuse rather than silently doing nothing. Names max128 UTF-8 bytes; app/cwd max259; at most16 args,
each max2047 bytes; file max1MiB, 128 profiles. An empty argument array retains PowerShell prompt
integration; nonempty arrays are passed unchanged.
Arguments containing control characters refuse because the launch-state TSV format cannot preserve
them. Captured commands use legacy K records for ordinary lines and lossless K2 records for tabs or
newlines; older builds ignore K2 records. The API field remains capturedCommands in either case.

`omp list` discovers local `.omp.json` themes, first-directory wins: POSH_THEMES_PATH, normal
winget/scoop/chocolatey locations, then app-data `omp-themes`. `omp set NAME [--persist]` requests
initialization only at an observed prompt in a fresh, writable PowerShell pane that has received
no input. After any input (including a prior OMP request), or adoption, it refuses: terminal marks
cannot prove an unfinished draft is empty. Use `config set omp-theme` for future shells instead.
It also refuses
unknown readiness, alternate-screen/readonly/exited/non-PowerShell panes. A successful reply means
initialization was written without synchronous error, not that OMP succeeded. Theme content and
OMP-generated shell code may execute commands; only apply themes you trust.

`config get/set omp-theme` reads or sets the path for eligible new PowerShell shells without
initializing existing ones; `none` clears it. Persisted initialization is not injected into adopted
shells or nonempty explicit profile argv. Paths must fit the host's encoded startup argument;
unsupported/overlong paths refuse. Live write followed by persistence failure reports both outcomes.

`config set restore-commands true` opts into captured K replay on future fresh restore; default false.
Review captured commands first. This does not immediately execute anything in existing panes.

### Commands and agent integration (P11)

Custom commands now support send/new/overlay/detached modes, keymap bindings and leader chords.
Opt-in CLI/hook/shell installers preserve unrelated configuration and keep backups of changed files.
Claude adoption uses exact process conversation evidence; YOLO and post-update resume use a guarded
prompt bridge, never a guessed transcript or fixed-delay command injection. App updates remain gated
to the installed release channel. See [commands and agent integration](docs/agent-integration.md) for
syntax, compatibility differences, refusal conditions and asynchronous outcome events.

## Session restore & the state file

agliteterm saves its workspaces and sessions whenever the tree changes and on exit, and rebuilds them on
the next launch (`--no-restore` starts empty instead). Everything about that is on disk and readable:

- **One state file per instance.** `%LOCALAPPDATA%\agliteterm\sessions.tsv` for the default
  instance, `sessions-<instance>.tsv` for a named one. **Because every window is its own
  process, each window restores only its own sessions** — sessions you created in
  `--pipe work` come back in `--pipe work`, never in the default window. That is the mundane
  reading of "my sessions are gone": right sessions, wrong window.
- **Format**: tab-separated UTF-8 text, `V1` header, one record per line — `W` workspace, `S` session
  (workspace index, name, app, cwd, then args), `F` flagged indices, `D` host session ids, `C` a
  session's context, `P` a session's split shell, `L` a split's layout (its axis and slot order,
  written only when it is not the default left/right unswapped), `K`/`K2` a session's captured commands,
  `A` active workspace; `C`, `P`, `L` and `K` name their session by its position among the `S` lines
  and are refused wholesale when that count does not add up. The format grows by *adding* line
  types, so a file written by an older build still restores, a line type this build doesn't write
  is still honoured when it finds one (`O`, focused workspace), and a file from a **newer** build is
  read for the lines this one knows rather than thrown away (a build before P4 restores an
  `L`-carrying split left/right, unswapped — the layout is lost, never the split). Every line type,
  field by field, is in [docs/state-file.md](docs/state-file.md).
- **What is saved**: the visible sessions, each with its *live* working directory (read from the
  shell process, so it follows you as you `cd`), its context and its captured command, and each
  session's split shell (its own app, cwd and slot) with its layout — top/bottom or left/right,
  and which side the session's own shell sits on after a `session swap` — so the split comes back
  with its owner the way it was. The quick, scratch and overlay covers — the three popups and a pane
  overlay alike — are hidden and are not persisted.
- **Writes are atomic, and keep one generation.** The save writes `sessions.tsv.tmp`, rotates the
  current file to **`sessions.tsv.bak`**, then renames the temp over the target — a crash or a full
  disk mid-write can no longer leave a truncated file where a good one was. A zero-session save is
  *refused* over a populated file (and says so in the log); the one legitimate empty is you closing
  the last session, which also deletes the `.bak` so what you just closed doesn't come back.
- **Restore order**: `sessions.tsv` → `.bak` if the primary is missing, empty, or parses to zero
  sessions → a fresh window. If the pty-host still holds the shells — lite was killed or the machine
  was shut down rather than closed — those shells are **still running** and get adopted live instead
  of relaunched. An adopted shell keeps everything it was running, and lite asks it to redraw, so the
  **screen comes back** — but the **scrollback does not**: it re-attaches to the live process with a
  fresh emulator, so only what is on screen is repainted, not the history the old window had. A shell
  that has already exited, or one another window is currently driving, is not adopted — it is
  relaunched (or left to its owner) instead.
- **Recovering by hand.** `--no-restore` starts empty, and the next save publishes *that* over
  `sessions.tsv` — but the generation you wanted survives as `sessions.tsv.bak`. **Copy the `.bak`
  somewhere safe first**: only one generation is kept, so the next save of the window you are looking
  at overwrites it in turn. Then close agliteterm, copy your saved file over `sessions.tsv`, and relaunch.
  `--diagnose` prints both files with their sizes (and the primary's contents), so you can tell which
  one holds your sessions before you copy anything.
- **"Restart everything"** (*File → Restart everything*) relaunches the **same** instance — it carries
  this window's `--pipe <name>` over, so it comes back reading the same state file. `--diagnose`
  prints the exact command line it would use.
- **A spec that won't start on this machine** (a profile whose exe only exists on your other PC, a
  cwd on an unmounted drive) stays in the tree as a `(failed to start)` entry with a note in its
  pane, rather than silently vanishing. Its name, workspace, cwd and args are kept and re-saved, so
  it starts normally again on the machine that has the app. Scripts can spot one without reading the
  log: `agwintermctl tree --json` reports `"failed"` and `"exited"` per session.

Every one of those branches names itself in `agliteterm.log`, and `test/restore-matrix.ps1` drives the
whole matrix — kill vs. graceful close, two windows at once, interrupted writes, `.bak` fallback,
bogus apps, old and future file formats — as regression cover.

If agliteterm exits at startup with **"pty-host did not become usable"**, a previous `agwinterm-ptyhost.exe`
is wedged: end it in Task Manager and relaunch. `agliteterm.log` records the connection attempt by attempt,
including the case it is really there for — a host left dying by a killed window, which answers a
handshake for a moment while refusing every real command.

## Reporting a problem

Run `agliteterm --diagnose` and attach its output plus `agliteterm.log`. The report is read-only and
safe to run while agliteterm is open; it prints the state file's path, whether that directory is genuinely
writable (a real write probe, which is what catches a redirected or policy-locked profile), the state
file's contents and its `.bak` generation, the resolved font, and the bundled pack inventory:

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

Use `--pipe <instance> --diagnose` to ask about a named instance — it reports *that* instance's
state file, which is the one its window restores from.

## The other one: agwinterm

**[agwinterm](https://github.com/yeroo/agwinterm)** is the full terminal this one is a sibling of —
C#/.NET on Win32 + Direct2D, custom-drawn chrome, any TrueType font with ligatures, images and
sixel, a dashboard, profiles, themes, and the complete control API. If your machine can afford it,
take that one; agliteterm exists for the machines that cannot.

Neither is a cut-down build of the other. They are separate programs that agreed on an interface,
and the agreement is enforced rather than promised: `test/control-api.json` here mirrors the
canonical contract in agwinterm, `tools/check-contract.ps1` compares them on every build, and both
repositories run the same conformance steps in CI. It has already caught real drift in both
directions.

The emulator core and pty-host are agwinterm's, consumed here as ABI-pinned release artifacts — see
[Building](#building).

Both are by [Boris Kudriashov](https://github.com/yeroo), and both owe their design to
**[umputun's agterm](https://github.com/umputun/agterm)**, the macOS terminal that treated AI coding
agents as first-class citizens first. 💜

## Building

Needs MSVC with the **VC++ ATL component** (WTL rides on the ATL headers):

```powershell
./build.ps1                 # -> bin\agliteterm.exe
./installer/build.ps1       # -> installer\Output\agliteterm-setup-<ver>.exe
```

### The core it rides on

agliteterm does not build the emulator core or the shell host. `agwinterm_core.dll` and
`agwinterm-ptyhost.exe` come from [agwinterm](https://github.com/yeroo/agwinterm) as ABI-stamped
release assets, pinned by [`native/pinned.json`](native/pinned.json) and fetched by
`tools/fetch-native.ps1`.

That C ABI carries **no compatibility guarantee across versions** — `src/main.cpp` requires exactly
one `kRequiredAbi`, and a mismatched pair refuses to load. While the client and the core lived in
one tree, a drift could only survive until the next rebuild; across two repositories it could
survive a whole release cycle and reach users. So the fetch reads the release's published ABI
manifest and **fails the build** on a mismatch, rather than letting it fail at load on someone
else's machine.

To build against a core you are changing:

```powershell
./build.ps1 -NativeDir C:\src\agwinterm\native\target\release
```

## Tests

```powershell
./test/run-all.ps1
```

`driving.unit.ps1` compiles an in-process C++ harness for search cells, casing and command-field
decoding (MSVC required). Integration checks drive the **built exe** and assert on observable
behaviour: the diagnostics log, the state file, the control pipe, and the windows themselves.
Rules the suite obeys, each learned from a real incident:

- always a sandbox instance (`--pipe <name>`); never the default instance, which owns real state
- never inject global input (`keybd_event`/`SendInput`) — it lands wherever focus happens to be
- capture windows with `PrintWindow`, never `CopyFromScreen`, which grabs whatever overlaps

`restore-matrix.ps1` is the big one: 34 cells covering kill vs. graceful close, two windows at once,
interrupted writes, `.bak` fallback, bogus apps, and old and future file formats. The checks that
drive the control pipe need `agwintermctl` — from an installed agwinterm, from `bin/` (the fetch
pulls it when the pinned release publishes it), or `$env:AGWINTERMCTL`. They skip with a message
when it is absent rather than failing obscurely. A check that needs a client newer than the
fetched release — `--stdin`, a strict `--size-percent`, `sidebar width N`, the `caller` field, all
agwinterm #226; `session context` and `restore capture`, agwinterm #233; `session split --axis`,
`split close`, `swap` and `focus`, agwinterm #238; `session overlay --pane`, `overlay copy` /
`text` and `session text --all` / `--lines`, agwinterm #250 — probes the client first
(`agwintermctl restore` answers a usage line on a post-#233 client; `session swap x` is refused
with "Nothing sent" by a post-#238 one, and `session overlay resize --pane left` by a post-#250
one, before any pipe is opened) and SKIPs on an older one
(`-Strict` turns that into a failure, which is the release gate). To run them all, point `$env:AGWINTERMCTL` at an agwinterm
dev build: `<agwinterm>\src\Agwinterm.Ctl\bin\Release\net10.0-windows\agwintermctl.exe`.

