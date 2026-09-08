# P9-lite — driving a pane

Batch **P9** of the parity programme (agwinterm `docs/plans/2026-09-03-parity-batches.md:201-204`,
Wave 2, lite-only): "`session.readonly` **first** — it is how you stop stray keys reaching a running
agent — then `session.focus` · `session.switch` · `session.resize` · `session.background` ·
`session.search` · `session.bind` · `session.restore`". Same model as P6/P7: no sibling agwinterm PR;
the reference is agwinterm's code and its reply strings, quoted below; where lite departs, the
departure is a named difference for `docs/lite-parity.md`.

Two of the eight need no work: **`session.focus` shipped in P4-lite** (`src/main.cpp:9494-9515`, the
three `SplitAxes` wordings, `control-honesty.ps1`'s P4 block) and **`session.background` stays
refused** — decision 8 below. Six verbs land here, in this order: `readonly`, `restore`, `bind`,
`resize`, `switch`, `search`. The first three are small and give an agent the most; the last three
carry new UI state and are where the batch's risk is.

Execution: branch `feat/p9-lite-driving-a-pane` **from `origin/main`** in a new worktree
`C:\Users\boris\source\agliteterm-p9`; rebase onto `main` when #45 (P6-lite) and the P7 PR merge,
before the PR is marked ready. **All line numbers below are on `320a0cf`** (origin/main at the time
of writing); #45 and P7 move `main.cpp` around the selection code, not around these sites, but
re-find every number before editing.

Decisions Boris delegated to the two agents (2026-09-08, "decide on all items and keep going") are
marked **[decided]**; each can be overturned by him in one line, and the plan says what changes.

## Overview

One invariant, stated once, quoted by name everywhere:

> **THE GATE.** A read-only surface takes no input from a HUMAN: no key (`sendBytes`, the popup's
> `WM_CHAR`, the control-key encodings), no Ctrl+V paste, and no MOUSE REPORT (P7's
> `mouseReportSurface` :4434-4460 — click, motion, release, wheel, frame and popup alike) reaches its
> pty. What is not a human passes untouched: the API's `session type` / `session write` (the agent's
> road), and the emulator's own answers to the program's queries (DA, DSR/CPR, focus/OSC replies —
> block those and the program hangs). `session paste` is refused `ok:false` naming the pane, never
> answered `pasted` with nothing pasted. Local mouse behaviour that writes nothing (selection, the
> scroll wheel on a non-reporting screen) is unchanged. Nothing about the surface's OUTPUT changes,
> and the flag is not persisted — a restart clears it, exactly as in agwinterm.
>
> Task 0 audits EVERY `ovIo(` call site and classifies it human / API / internal in a table in
> Technical Details; THE GATE is placed on the human rows, none of the others, and the table is the
> proof that the three routes named above are the whole set.

1. **`session readonly [on|off|toggle|state|get] [--target]`** (Task 1). Per-surface `readOnly` flag
   (`struct Session`; a popup is a surface too — `active` on a covered pane targets the overlay, the
   surface-verb rule of P5). Replies `on` / `off`. An op outside the five is refused (agwinterm's
   `_ => !p.ReadOnly` toggles on a typo — difference (j)); a missing target is refused `ok:false`
   `session not found` (lite's rule; agwinterm answers `ok:true "no session"` — difference (k), the
   P6 (a) class, follow-up issue in agwinterm). `READ-ONLY` shown in the status bar's size part while
   the focused surface is read-only (agwinterm's `Pill("READ-ONLY")`, `Program.Services.cs:334`); a
   palette row + Edit-menu item "Toggle Read-Only Pane" and a rebindable, unbound-by-default
   `KB_READONLY` (`Key_ReadOnly`), as agwinterm ships `toggle_read_only` unbound (`Keymap.cs:66`).
2. **`session restore <command…>|none --target <pane>`** (Task 2). A per-shell **pinned** command,
   typed into the shell after a restart. Replies agwinterm's raw JSON `{"action":"pinned"|"cleared",
   "pane":"<id>","session":"<id>"[,"command":"<cmd>"]}` (`ControlServer.cs:674-689`); the three
   refusals verbatim: empty/`active` target → `session.restore needs a pane: pass --target <pane-id>.
   A pin outlives the pane that is active now, so there is no active-pane default (inside a session,
   AGWINTERM_SESSION_ID is that pane's id). Nothing pinned.`; no match → `no pane or session matches
   '<target>'. Nothing pinned.`; a cover → `'<id>' is a scratch/overlay/quick pane, which is never
   restored; a pin there would be lost at the next restart. Nothing pinned.` State line `R` (K's
   shape, by role); tree key `restoreCommands` (the `capturedCommands` shape). Replay: 2500 ms after
   the shell is up (agwinterm `Program.Services.cs:1712-1724` — a DELAY, not a readiness proof; the
   same as the reference, documented as such), skipped for a shell the `D` line adopted and for a
   shell with a binding (Task 3). THE REPLAY RULE: the timer carries only the shell's pane id; on
   fire the shell is re-resolved under `LockG`, its CURRENT pin/binding and its `data` handle are
   copied out, the lock is RELEASED, and the write goes through `ovIo` outside it — never `LockG`
   across pty I/O (P7's lock/I-O separation, `g_resizeLock`'s lesson in P2). A shell that is gone,
   adopted, replaced, or whose pin/binding was cleared or changed since arming replays what it holds
   NOW (nothing, if nothing) — arming never captures a command. `replayOnRestore` in `restore capture`'s reply
   **stays `false`** — it means "captured commands will be typed back", and lite still never types a
   capture (agwinterm does so only under `restore-commands`, P10's configuration surface).
3. **`session bind [agent|none] --target <pane>`** (Task 3). A per-shell `agentResume` string typed
   into the shell 2500 ms after a restart instead of the pin (agwinterm `:1693-1710`; a bound pane's
   pin does not replay). Reply `bound` for a set and for a clear (agwinterm's shape); no target /
   no match → `ok:false session not found` (agwinterm's `Err("session not found")`). Resolution:
   pane id, exact or prefix, OR a session id/name → that session's own shell (agwinterm resolves pane
   ids only, `FindPaneById`; in agwinterm a session id IS its first pane's id, in lite a promoted
   session's id is not — the P4 rule — so lite widens rather than refuses; difference (l)). An EMPTY
   or `active` target is refused `session not found` BEFORE THE RULE's remap (a binding names one
   shell for the next restart; "whatever is focused now" is not that shell). The agent string is
   stored AS TYPED — `none`/whitespace clears, nothing else is touched, no lower-casing (agwinterm
   lower-cases at `Program.ControlHost.cs:1191`; a command line is case-sensitive to the program it
   starts — difference (s)) — and is replayed verbatim plus `\r`. Written and saved BEFORE the reply
   (lite's convention since P3; agwinterm posts and answers first). State line `B` (K's shape); not
   in the tree (agwinterm has it in no tree either).
4. **`session resize --split-ratio r | --grow-left/right/top/bottom n`** (Task 4). The divider of the
   focused session's split moves; `slotRect` :1549-1564 stops being a fixed half. Reply `resized`;
   refusals verbatim from `SplitAxes` (agwinterm `Program.Sessions.cs:1885-1911`): `session is not
   split (one pane); there is no divider to move`; `--grow-left/--grow-right mean nothing on a
   horizontal split (top/bottom panes); use --grow-top/--grow-bottom; the divider was not moved` and
   its mirror. Ratio = slot 0's share, clamped `0.05..0.95`, then each slot never below one cell
   (`paneGridSize` :1577-1592's rule keeps the pty sane); grow = cells × `g_cw`/`g_ch`. Persisted on
   a new state line `G owner ratio` (written only when the ratio is not `0.5`, downgrade-safe by the
   unknown-line rule); tree `splitRatios: [a, b]` in slot order (`"0.###"`, agwinterm
   `ControlServer.cs:452-457`). `ratio` is accepted as a JSON number or a string (lite's parser
   flattens both); a value that is not a number is refused `session resize: --split-ratio needs a
   number between 0.05 and 0.95; the divider was not moved` (agwinterm silently ignores a string
   ratio — difference (m)). No divider drag with the mouse (P10+; the sidebar splitter is the only
   drag today).
5. **`session switch [begin|advance|advance-back|commit|cancel]`** (Task 5). An MRU walk over the
   visible sessions, driven by the verb: `begin` snapshots the order and the session the walk
   started from, `advance`/`advance-back` (`next`/`back`/`prev`/`previous` accepted, agwinterm's
   aliases) select the next/previous session in MRU order as a PREVIEW, `commit` makes the current
   one most-recent, `cancel` returns to where the walk began. Reply = the active session's display
   name (`session N` for an unnamed one — the sidebar's text; agwinterm returns `ses.Name`, empty
   for an unnamed one — difference (n)); `(none)` with no session. An op outside the set is refused
   (agwinterm answers `ok:true "unknown op '…'"` — difference (j) again). The MRU order is kept by
   every focus change (`selectPrimary`/`selectIdx`, `session select`, `session go`, sidebar clicks,
   `cycleSession`, popup focus), not by the walk alone. `KB_NEXT`/`KB_PREV` keep walking tree order
   (difference (o): lite's keys are not an MRU walker; the verb is).
6. **`session search [query] [--next|--prev|--close] [--target]`** (Task 6). Case-insensitive search
   over the ACTIVE surface's history + grid (agwinterm `Program.Input.cs:1005-1039`; `target` accepted
   for shape, v1 searches the active surface — the same as agwinterm's comment
   `Program.ControlHost.cs:808`), matches highlighted in `paintPane`, the current match scrolled into
   view on the main screen (THE PIN of P7: never on the alt screen), reply = `N of M` / `no matches` /
   `""` / `closed` (`SearchStatus`, `Program.Input.cs:1060-1062`). THE MATCH RULE: a row is searched
   as CODE POINTS (`FfiCell.rune` is already a Unicode scalar; Windows invariant casing — never
   over UTF-8 bytes, where a Cyrillic or wide glyph is 2-4 bytes and a byte offset is not a column),
   with a code-point → cell map kept beside the row so a match is stored in CELLS
   (`{absRow, colStart, colEnd}`; a wide glyph occupies two cells, a match ending on it ends after
   its spacer); the paint re-checks that the row still holds the matched text before it inverts
   anything (output moves rows; a stale match paints nothing rather than the wrong cells); `N of M`
   may be stale until the next verb call, and says so in the README. The status bar's size part
   shows `FIND N of M` while a search is open. **No find bar and no Ctrl+F**: lite gets the verb and the
   paint, a key-driven bar is P10+ (difference (p)). A missing session → `ok:false session not found`
   (difference (k)).

**Not in this batch** — `session.background` **[decided: stays refused]**: lite's painter is GDI text
with no image pipeline; a watermark needs decode (WIC), alpha-blend behind every glyph run, a copy
under `%LOCALAPPDATA%\agliteterm\backgrounds`, a state line and a tree key — the largest surface in
the batch for the least agent value. The skill's NOT list keeps it with a reason ("lite draws no
images"); `docs/lite-parity.md` records it as a permanent difference (q). If Boris wants it, it is
its own batch after P10.

## Context (from discovery)

All in `src/main.cpp` unless said (on `320a0cf`):

- **Dispatch** `ctlDispatch` :8339; helpers `ctlOk`/`ctlOkStr`/`ctlErr` (`src/control.h:167-169`);
  `JsonReq` flattens `args` to `"args.<key>"` STRINGS (`control.h:17-24`, :77-118) — `req.get(k)` is
  `""` for absent AND empty (the `restore.capture` arm reads the map directly to tell them apart,
  :9198-9200). `resolveTarget` :7616-7645 (empty/`active` → `focusedSession()`; exact `id`; exact
  `paneId`; ≥4-char prefix; case-insensitive name; the ambiguity wording). Refusal pattern:
  `if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);`.
- **THE RULE** (the `active` remap) :8602-8612: for an empty/`active` target every verb but
  `session.type/write/output/text`, `surface.cursor`, `session.copy/paste/overlay` is redirected to
  `focusedShell()` and, unless pane-class (`session.close/split/split.close/swap`, `restore.capture`),
  to `splitOwnerOf(shell)`. New verbs are added to a list DELIBERATELY: `session.readonly`,
  `session.search` join the surface list (they act on what the keys reach); `session.bind`,
  `session.restore` are pane-class (`restore` never accepts `active` at all — its refusal runs
  BEFORE the remap, Task 2); `session.switch`, `session.resize` take no target (the active session).
- **Cover refusals** `sessionIdentityCover(verb, paneId, nothing)` :7514-7519 (P5's wording);
  `isCoverLocked` :7522; `surfaceOf` (P5), `focusedShell`, `splitOwnerOf`, `focusedSession`.
- **Unknown verb** :9902-9904 `unknown command '<cmd>' (lite subset)`; the skill's NOT list
  :8293-8296 (five names leave it; `switch`/`resize` were never listed — an agent reading the skill
  today gets `unknown command` for them unwarned); README `:70-71` "48 verbs" (the count moves).
- **Input** `sendBytes` :4294-4297 (`focusedSession()` → `ovIo`), `handleKeyDown` :4730 (control
  keys :4811-4830 via `sendBytes`), the popup's `WM_CHAR` :5940-5947, `OnChar` :6544-6550;
  `pasteClipboard` :4315-4339 writes `ovIo` DIRECTLY; `session.type` :8635-8661 and `session.paste`
  :9553-9575 write `ovIo(target->data …)` directly; `session.write` :8662-8674 feeds the emulator.
  So THE GATE is one test in `sendBytes` + one in `pasteClipboard` + one refusal in `session.paste`.
- **Status bar** `updateStatus` :4875; parts `{120, 360, 470, -1}` :10662, part 2 = `cols × rows`
  (P7 appends `MARK` there; P9 appends `READ-ONLY` and `FIND N of M` — order: size, `MARK`,
  `READ-ONLY`, `FIND…`, ` · `-separated). `[LiteHonesty]::StatusPart` (`test/control-honesty.ps1:721`).
- **Keys** `KB_*` :978-980, `kKbInfo` :982-994, `loadKeys` :2805 / `saveKeys` :2819 (`HKCU\Software\
  agliteterm\Key_*`), `runKbAction` :4763, palette `kPalActions` :1147+, menu ids near :5115.
- **Sessions** `cycleSession` :2635-2648 (tree order, hidden skipped; `KB_NEXT`/`KB_PREV` :4708-4709,
  `IDM_NEXT`/`IDM_PREV` :1006, :5082-5083, palette :1158-1159); `session.go` :9577-9599; every
  `g_focus`/`g_pane[0]` write (P7's Task 4 lists them: :2111, :2129, :2601, :2628, :4755-4756, :6633,
  :6710, :9566, :10490 — P7 may have given them a choke point; reuse it for the MRU touch).
- **Layout** `slotRect` :1549-1564 (fixed `half`), `paneRect` :1566, `paneGridSize` :1577-1592,
  `syncPaneSizes` :1833, `displayedLayout`, `splitBlockFields` :7566-7573 (tree: `paneIds`,
  `focusedPane`, `axis`), the tree node's `cols`/`rows` = the OWNER's shell :8380-8386. State file
  `docs/state-file.md` (`L owner axis order`, `K i pane0 pane1`, "unknown line types are ignored",
  per-field validation named in the log); save :3216-3218 (`K`), load :10327-10332 / :10386.
- **Restore** `Session::capturedCmd` :412-413, `restore.capture` :9186-9289 (`replayOnRestore`
  false, comment :9191-9195), tree `capturedCommands` :8397-8409; the restore path creates shells
  fresh :10333-10340; `--no-restore` :159/:10429 (the sandbox always passes it, `ui-lib.ps1:175`).
- **Emulator** the Rust `emu_*` FFI: `session.text --all` (P5) reads history + grid — the same reader
  feeds search; `FfiEmuInfo` (`historyCount`, `isAltScreen`, cursor); `paintPane` :3844 (P7 adds the
  selection band :3958-3973 — the search highlight is a second band with a different brush, painted
  AFTER the selection so a selected match stays visible as selected).
- **agwinterm reference**: `ISessionHost.cs:206-207` (readonly), `Program.ControlHost.cs:720-726`,
  `Program.Input.cs:31-35` / `:977` (the two gates), `Program.Services.cs:334` (pill), :1486/:1647
  (`Ratio` persisted), :1693-1724 (replay: bind, then pin), `Program.Sessions.cs:604-666` (MRU walk),
  :1885-1911 (resize), `ControlServer.cs:246`, :274-280, :321-323, :341, :425-460 (tree), :674-689,
  `Program.ControlHost.cs:1186-1194` (bind), :1223-1240 (restore), :808-820 (search),
  `Program.Input.cs:1005-1077` (search), `SplitAxes.cs` (wordings), `SessionRestoreTests.cs`,
  `tests/integration/restore-roundtrip.ps1:202`, `src/Agwinterm.Ctl/Program.cs:330-335, :385,
  :432-450` (the CLI already has every subcommand — no client change; a `$cliHasP9` probe is not
  needed), `AgentSkill.cs:89-95, :154-155, :312-314, :376-390`.

### Vocabulary

- **surface**: what a pane shows — the shell, or its popup (overlay/quick/scratch) while one is up.
  `readonly` and `search` are surface verbs; `bind` and `restore` are shell verbs (a popup is never
  restored, so it can carry neither).
- **pin**: the `session restore` command of a shell; **binding**: its `session bind` agent. Exactly
  one of them replays after a restart: the binding wins (agwinterm `:1712` `if (AgentResume …)
  skip`).
- **MRU order**: the visible sessions by the time each was last focused, most recent first.

### lite-parity differences (for agwinterm `docs/lite-parity.md`, the docs PR after merge)

- **(j)** an op outside a verb's set is refused `ok:false` (`readonly`, `switch`); agwinterm toggles
  / answers `ok:true "unknown op"`. Follow-up issue in agwinterm.
- **(k)** a missing target is refused `ok:false session not found` on `readonly`, `search`
  (agwinterm `ok:true "no session"`). Same follow-up (the P6 (a) class).
- **(l)** `bind` resolves a session id/name to the session's own shell (agwinterm: pane ids only).
- **(m)** `resize` accepts `ratio` as a number or a string and refuses a non-number (agwinterm ignores
  a string silently, then `resized`).
- **(n)** `switch` answers `session N` for an unnamed session (agwinterm: the empty name).
- **(o)** `KB_NEXT`/`KB_PREV` walk tree order; only the verb walks MRU.
- **(p)** no find bar / Ctrl+F; search is verb-driven, highlighted and shown in the status bar.
- **(q)** `session background` stays refused: lite draws no images.
- **(r)** `session paste` on a read-only surface is refused `ok:false` `session paste: '<id>' is
  read-only; nothing pasted` — agwinterm answers `pasted` with nothing pasted (follow-up issue).
- Not a difference: `replayOnRestore` stays `false` (true in agwinterm only under
  `restore-commands`, which lite gets in P10); the read-only flag is not persisted in either product.

## Constraints

- Sandbox per `qa/product.md` (`--pipe`, throwaway profile, `--no-restore`); PostMessage to the
  sandbox's own hwnd only (`WM_CHAR`/`WM_KEYDOWN` for THE GATE's checks) — never `SendInput`/
  `keybd_event`; `PrintWindow` for captures.
- The clipboard and `HKCU\Software\agliteterm` are shared with the user's real app and every other
  sandbox: a test that writes either saves it first and restores it in `finally` (`Key_ReadOnly` is
  a new registry value; a test that sets it restores it). THE GATE's paste check plants a marker in
  the clipboard through a NEW `[LiteClipboard]` in `test/ui-lib.ps1` — a port of agwinterm #256's
  `Agwinterm.Win32ControlTest.Clipboard` (`tests/integration/win32-control.ps1`): EVERY format's
  bytes taken under one `OpenClipboard` with the sequence number, the marker written only while that
  sequence still stands, the restore under one `OpenClipboard` proven by a read-back, NOT RUN
  (FAIL under `-Strict`) on a format that is not global memory (a GDI bitmap, a metafile, a palette,
  owner-display, the private range) — never `test/clipboard.ps1`'s text-only `[ClipIn]`. Port the
  helper only once #256's review is closed on it (its restore/race findings are being fixed there);
  until then THE GATE's paste check is the last check written in Task 7, not the first.
- **The hub suite token**: every interactive suite or probe run acquires it first (`python
  C:\Users\boris\AI\bin\suite-token.py acquire --owner codex-agwinterm --run <id> --worktree <path>
  --holder-pid <pid>`, exit 0 AND `ok:true`), holds it through teardown and the restores, releases
  with `--cleanup-confirmed` only when the teardown is PROVEN (a suite that reports TEARDOWN UNCERTAIN
  = stop and ask, do not release), and mails the other agent a release report. Never run a suite while
  the other agent holds the token. **Restart cells** (Task 2/3's replay) use `restore-matrix.ps1`'s
  `Start-Lite`/`Stop-Lite -Kill` and its `owned-procs.ps1` teardown — the ownership-proven one (#47)
  WITH lite #48 (Claude's PR: tagged `-w <tag>` markers, exact-tick identity, an exit bound from the
  last query that saw the row, TEARDOWN UNCERTAIN → cell FAIL): #48 merges BEFORE Task 7's restart
  cells are written or run. Until it is in `main`, no restart cell runs, and no cell adds a PING
  sweep, a `Get-Process`-by-name stop or a wrapper of its own.
- Every `g_sessions` touch under `LockG`; no `SendMessage` from the pipe thread; post
  (`WM_APP_REFRESHTREE`, `InvalidateRect`). Replay typing happens on the UI thread from a timer,
  per THE REPLAY RULE: the shell re-resolved and its handle copied out under `LockG`, the lock
  RELEASED, then `ovIo` on that handle OUTSIDE the lock — never `sendBytes` (THE GATE would eat it,
  and it must reach the right shell whatever is focused), never `LockG` across pty I/O. The copied
  handle's lifetime: a shell's `data` handle is closed only on the UI thread (`closeSession` and the
  exit path), and the timer tick IS the UI thread, so nothing can close it between the copy and the
  write — Task 2 states this in a comment at the copy and Task 0's audit confirms no other thread
  closes a shell's handle (if one does, the replay takes a duplicate: `DuplicateHandle`, closed after
  the write).
- Explicit `git add` paths; `.ralphex/` and `.revmux/` are never committed; commit trailers per the
  executor's session. Build only when no suite runs in the tree; never build while the other agent's
  suite runs anywhere (the token).
- Do not edit `C:\Users\boris\source\agliteterm` (Claude's tree), `agliteterm-p6` or `agliteterm-p7`;
  the P9 worktree is the only tree this batch writes.

## Testing Strategy

`test/control-honesty.ps1 -Strict` gains a **P9 block** (verbs on the sandbox, THE GATE by posted
keys), `test/restore-matrix.ps1` gains **two restart cells** (a pin replays; a binding wins over the
pin and an adopted shell replays neither), `test/control-read.ps1` gains the new tree keys. Every
check names the rule it pins ("THE GATE: …"). Checks, in order:

- **readonly**: `session readonly` on the sandbox's shell → `on`; `state` → `on`; post `WM_CHAR 'x'`
  ×3 to the hwnd → after 500 ms `session text` unchanged (THE GATE: keys); plant the clipboard
  marker, post Ctrl+V (`[LiteUi]::Chord('V')`) → unchanged (THE GATE: paste); `session type "echo
  P9-OK`r"` → `P9-OK` appears (the API passes); `session paste` → `ok:false` `… read-only; nothing
  pasted`; `StatusPart(2)` ends with `READ-ONLY`; `off` → `off`, the same key now reaches the shell;
  `readonly bogus` → `ok:false`; `readonly --target nonsense` → `ok:false session not found`; with an
  overlay open, `readonly on` (no target) → the OVERLAY is read-only (`state --target <overlay id>`
  `on`, `--target <shell id>` `off`) — the surface rule; `readonly on --target <split shell id>` on
  a split → that shell only. Registry: `Key_ReadOnly` set to Ctrl+Shift+R (restored in `finally`),
  relaunch, chord → `state` flips.
- **restore**: `session restore 'echo PIN' --target <shell>` → the JSON with `pinned`, `pane`,
  `session`, `command`; tree `restoreCommands` keyed by pane id; `none` → `cleared`, the key gone;
  no target → the `needs a pane` refusal verbatim (also with `--target active`); `--target nonsense`
  → `no pane or session matches 'nonsense'. Nothing pinned.`; a cover id → the `never restored`
  refusal; `restore capture` still answers `replayOnRestore:false`. State file: after a pin, the
  `R` line is present and validated (a malformed `R` is dropped and named in the log — `Log-Has`).
- **bind**: `session bind claude --target <shell>` → `bound`; `none` → `bound`; no target →
  `ok:false session not found`; a session id → `bound` and the `B` line names the session's own
  shell's slot; a cover → the cover refusal.
- **restart cells** (`restore-matrix.ps1`): (1) seed a pin, `Stop-Lite -Kill`, `Start-Lite` (WITHOUT
  `--no-restore`), wait ≤ 6 s → `session text` of the restored shell shows the pin's output; (2) seed
  a pin AND a binding of a harmless command (`echo BOUND`) → `BOUND` appears, the pin's output does
  not; (3) an adopted shell (the `D` line matches a live pty-host id — the matrix's existing adopt
  cell) → neither appears within 6 s.
- **resize**: on an unsplit session `session resize --split-ratio 0.3` → the `no divider` refusal;
  split vertical, `--grow-top 2` → the horizontal-mirror refusal naming `--grow-left/--grow-right`;
  `--split-ratio 0.3` → `resized`, tree `splitRatios` `[0.3, 0.7]`, and the owner node's `cols` is
  ~30 % of what it was (with the split shell's cols ~70 %: read both via `session text`'s width or a
  `PrintWindow` of the two rects — say which); `--grow-right 5` → the owner gains ~5 cols;
  `--split-ratio 0.001` → clamped to `0.05` and still ≥ 1 cell; `--split-ratio abc` (raw JSON via
  `Send-Raw`: `"ratio":"abc"`) → the `needs a number` refusal; `"ratio":0.4` (a JSON number) and
  `"ratio":"0.4"` (a string) both `resized`. Persistence: `G` line written only when ≠ 0.5 (`Stop-Lite
  -Kill`, `Start-Lite`, the ratio is back — a restart cell); an older file without `G` restores 0.5.
- **switch**: three sessions A, B, C; focus A, then C, then B → `switch begin` → reply `B`;
  `advance` → `C` (the most recent before B), `advance` → `A`, `advance-back` → `C`; `cancel` → `B`
  is active again; `begin`, `advance` → `C`, `commit` → `C` active and now most-recent (`begin`,
  `advance` → `B`); `switch bogus` → `ok:false`; with one session `begin` → its name and `advance` →
  the same name; `switch` with no session (all closed) → `(none)`.
- **search**: print `alpha 1..30` with one `NEEDLE` in history and one on the grid; `session search
  needle` → `1 of 2`, `session text` shows the history match scrolled into view; `--next` → `2 of
  2`; `--next` → `1 of 2` (wraps, agwinterm `SearchStep`); `--prev`; `session search zzz` → `no
  matches`; `StatusPart(2)` has `FIND 1 of 2`; `--close` → `closed`, the status text gone, `session
  text` unchanged; on the alt screen (`\e[?1049h` fixture from P7) a match in history is counted but
  the view does not scroll (THE PIN); a `PrintWindow` before/after `session search` differs (the
  band) and after `--close` equals before. THE MATCH RULE's cases: a row `xx игла yy` (Cyrillic,
  two bytes a glyph) → `session search ИГЛА` (upper-case query) → `1 of 1`, and the `PrintWindow`
  band sits on cells 3..6 of that row — proven by comparing the inverted columns with a capture of
  `session search yy` (cells 8..9), not by byte arithmetic; a row `漢字 needle` (wide glyphs, two
  cells each) → `session search needle` → the band starts at cell 5, not 3; a match ENDING on a wide
  glyph (`search 字`) → the band covers both of its cells; a row with `iglA` → `search IGLa` → found
  (Windows invariant scalar casing on both sides).
- **NOT list / unknown**: `session background set x.png` → still `unknown command 'session.background'
  (lite subset)`; the skill text lists it with the reason.
- `test/run-all.ps1 -Strict` green under the token; `tools/check-contract.ps1` green (no contract
  change: P9 adds no step to `control-api.json` — decision 13).

## Progress Tracking

- [ ] Task 0: read `main.cpp` on the rebased tip; re-find every line number; the choke point for
      focus changes (P7's, or the one this batch makes)
- [ ] Task 1: `session readonly` — THE GATE, status text, key/palette/menu
- [ ] Task 2: `session restore` — pin, `R` line, tree key, replay timer
- [ ] Task 3: `session bind` — `B` line, replay precedence
- [ ] Task 4: `session resize` — ratio in `slotRect`, `G` line, tree `splitRatios`
- [ ] Task 5: `session switch` — MRU order + walk
- [ ] Task 6: `session search` — matcher, band, status text
- [ ] Task 7: tests (honesty P9 block, restart cells, control-read keys)
- [ ] Task 8: docs (skill, README, `docs/state-file.md`, qa, this plan)
- [ ] Task 9: [Final] verify acceptance criteria

## Implementation Steps

### Task 0: re-read

Rebase target known (#45 merged? P7 merged?). Re-find every `:NNNN` above. Find the focus-change
choke point P7 introduced for mark mode (`endMarkMode` or its fallback) — Task 5's MRU touch and
Task 1's status update hang off the same place. Record the findings under Technical Details.

### Task 1: `session readonly`

- `struct Session` gains `bool readOnly = false;` (not saved: the writer never emits it).
- THE GATE: `sendBytes` :4294 → `if (!s || s->readOnly || s->data == INVALID_HANDLE_VALUE) return;`
  with THE GATE's comment (the one statement); `pasteClipboard` :4315 → the same test on the surface
  it writes to, and the popup's `WM_CHAR` :5940 goes through `sendBytes`/`sendUtf8` already (verify
  — if it writes `ovIo` itself, route it through the gate). `session.paste` :9553 → before the write,
  `if (target->readOnly) return ctlErr("session paste: '" + target->paneId + "' is read-only; nothing
  pasted");`. `session.type` and `session.write` unchanged (the API passes — say so in THE GATE's
  comment, quoting agwinterm `Program.Input.cs:31-35` vs `HandleType`).
- Verb `session.readonly` in the surface list of THE RULE :8603-8604. Arm: `op = args.op` default
  `toggle`; `on|off|toggle|state|get` else `ctlErr("session readonly: op '<op>' is not one of on, off,
  toggle, state or get; nothing changed")`; target resolved by the standard pattern (missing →
  `session not found`); `LockG`; `Session* s = target` — standard resolution already selected the
  surface, and an explicit shell target must not be redirected to its overlay; flip/read;
  `InvalidateRect` + `updateStatus()` posted; reply `ctlOkStr(s->readOnly
  ? "on" : "off")`.
- `updateStatus` :4875 part 2 gains `READ-ONLY` when the focused SURFACE is read-only (after `MARK`,
  before `FIND`). The sidebar row gets no marker (the flag is per surface, the row is per session).
- `KB_READONLY` before `KB_COUNT`, `kKbInfo` `{ L"Toggle Read-Only Pane", L"Key_ReadOnly" }`, no
  seeded default; `runKbAction` → toggle on `focusedSurface()` + status + invalidate; palette row and
  Edit-menu item `IDM_READONLY` ("Toggle Read-Only Pane", agwinterm `Program.Chrome.cs:812`).

### Task 2: `session restore`

- `Session` gains `std::string restoreCmd;` per shell (the split shell has its own `Session`, so
  one field; the `R` line pairs them by role like `K`).
- Verb, BEFORE THE RULE's remap (:8602): `if (cmd == "session.restore" && (targetWord.empty() ||
  targetWord == "active")) return ctlErr(<the needs-a-pane text verbatim>);` then the normal resolve
  with the custom no-match text `no pane or session matches '<t>'. Nothing pinned.`; `LockG`; cover →
  `ctlErr("'" + id + "' is a scratch/overlay/quick pane, which is never restored; a pin there would
  be lost at the next restart. Nothing pinned.")`; a session id → its own shell (`FindControlPane`'s
  behaviour); `command` from the field map: absent, whitespace or `none` (case-insensitive) → clear;
  set; **save the state file** (lite's convention, P3's `restore capture`); reply
  `ctlOk("{\"action\":\"pinned\",\"pane\":\"…\",\"session\":\"…\",\"command\":\"…\"}")` (JSON-escaped
  through the existing helper; `command` omitted on `cleared`).
- State: `R i pane0 pane1` written after `K` by the same convention (empty field = none, both by
  ROLE, one line per session with at least one pin); load beside :10327/:10386; `docs/state-file.md`
  row with the downgrade sentence (an older build ignores `R` and never replays — nothing lost but the
  pin, and it drops the line on its next save).
- Tree: `restoreCommands` beside `capturedCommands` :8397-8409, keyed by pane id, only when a pane
  has a pin (agwinterm `AppendPaneMap`).
- Replay: when the restore path creates a shell :10333-10340 that has a pin or a binding AND was not
  adopted, push its pane id onto `g_replayQueue` and arm ONE one-shot timer (id **4** `kReplayTimer`;
  P7 took 3) for 2500 ms — one timer, one queue; the tick drains the queue. Per id, THE REPLAY RULE:
  under `LockG` re-find the shell by pane id; gone, adopted since, or no pin AND no binding → skip
  (logged `replay skipped for <id>: <why>`); else copy the binding (else the pin) and the `data`
  handle out, RELEASE the lock, then `ovIo(handle, text + "\r")` outside it; log `replayed pin into
  <id>` / `replayed binding <agent> into <id>` (`logInfo`, so `Log-Has` can pin it). Never through
  `sendBytes`; never `ovIo` under `LockG`. The handle lifetime argument is in Constraints (the tick
  is the UI thread; only the UI thread closes a shell's `data`).

### Task 3: `session bind`

- `Session::agentResume` per shell; verb pane-class in THE RULE's list, but an EMPTY or `active`
  target is refused `ctlErr("session not found")` BEFORE the remap (the same early-return shape as
  `session.restore`'s `needs a pane` guard, Task 2 — a binding names one shell for the next restart,
  not whatever is focused); resolution: `resolveTarget` then `target->` own shell (a session id or
  name → the session's own shell; a split shell's pane id → that shell; a cover →
  `sessionIdentityCover("bind", …, "bound")`); `agent` default `claude`, `none`/whitespace → clear,
  else stored AS TYPED (no lower-casing, no trimming inside — difference (s)); set, save the state
  file, reply `ctlOkStr("bound")`. No match → `session not found`.
- State line `B i agent0 agent1` (K's shape); load; doc row. Not in the tree.
- Precedence in the replay tick: binding first (Task 2).

### Task 4: `session resize`

- `Session` (the owner) gains `float splitRatio = 0.5f;` — slot 0's share. `slotRect` :1549 →
  `int a = (int)lround(span * ratio)` for slot 0 with `ratio` clamped `0.05..0.95` and then to
  `[cell, span - cell]` (one cell of `g_cw`/`g_ch` each side), the divider at `a`; `paneGridSize`
  unchanged (it derives from the rect). `syncPaneSizes` after every change; `InvalidateRect`.
- Verb (no target; the active session — the displayed owner, `displayedOwner()` as `session.focus`
  uses): not split → `ctlErr(kSplitNoDivider)` (new constant beside `kSplitNotSplit` :7315, agwinterm
  `SplitAxes.NoDivider`); read `ratio` (number or string → `strtod`; present but not a number → the
  `needs a number` refusal), `grow-left/right/top/bottom` (ints; non-int → `session resize:
  --grow-… needs a whole number of cells; the divider was not moved`); axis check → the two verbatim
  refusals; ratio applied first, then `shift = horizontal ? bottom - top : right - left` cells →
  `ratio += shift * cell / span`; clamp; `syncPaneSizes`; **save** (the `G` line); reply
  `ctlOkStr("resized")`.
- State line `G owner ratio` (`%.3f`), written only when `ratio != 0.5` after clamping; load
  validates `0.05..0.95` (else `0.5`, named in the log); doc row (downgrade: an older build ignores
  `G`, restores the half, drops the line).
- Tree: `splitRatios: [a, b]` inside the split block :7566-7573 in SLOT order (after a swap, slot 0
  is the split shell — the ratio is slot 0's share regardless of which shell sits there, the same as
  agwinterm's `Pane.Ratio` on the pane in that slot).

### Task 5: `session switch`

- `static std::vector<std::string> g_mru;` (session ids, most recent first) maintained by the
  focus-change choke point (Task 0): on every change of the displayed session, move its id to the
  front; on close, erase. `g_walk` state: `active`, `startId`, `cursor` (index into a snapshot of
  `g_mru` taken at `begin`, visible non-exited sessions only, in MRU order).
- Verb (no target): `op` default `advance`; `begin` → snapshot, `cursor = 0`, `active = true`;
  `advance`/`next` → `cursor = (cursor + 1) % n`, select that session as a PREVIEW (the normal select
  path, which touches `g_mru` — so the snapshot, not `g_mru`, drives the walk); `advance-back`/
  `back`/`prev`/`previous` → the mirror; `commit` → `active = false` (the current session is already
  at the front); `cancel` → select `startId` (if it still exists), `active = false`; an `advance`
  with no walk begun → begins one first (agwinterm's `MruWalk` does `StartWalk` implicitly — check
  `Program.Sessions.cs:604-640` and copy whichever it does); unknown → `ctlErr("session switch: op
  '<op>' is not one of begin, advance, advance-back, commit or cancel; nothing changed")`. Reply =
  the displayed session's name (`session N` when unnamed, the sidebar's rule), `(none)` with none.
  One session: `begin` and `advance` both answer its name and change nothing.

### Task 6: `session search`

- `struct Search { bool open; std::string query; std::vector<Match> matches; int cur; std::string
  sess; }` — one, for the active surface (v1). `Match = { int absRow, colStart, colEnd }` in CELLS.
  Per THE MATCH RULE: walk the same rows `session text --all` reads (history rows + grid rows) as
  CELLS, reading each `FfiCell.rune` as a Unicode scalar (a wide glyph's spacer adds no code point)
  into a `std::u32string`; decode surrogate pairs only in the UTF-16 query,
  plus a parallel `std::vector<int>` code-point → cell column; lower-case the query and the row with
  Windows invariant scalar casing; match by `find` over the code-point string, no wrap across rows
  (agwinterm `RecomputeSearch` :1005-1039 is row-local too); map the match's first and one-past-last
  code point through the column map to `colStart`/`colEnd` (a wide glyph at the end → `colEnd`
  after its spacer). NEVER search UTF-8 bytes: a byte offset is not a column once a row holds
  Cyrillic or CJK. Recompute on every verb call, not on every output (agwinterm recomputes on the
  verb and on `SearchStep`; a live recompute is not in this batch — matches go stale as output
  scrolls; the paint re-checks each match's row text before inverting; say so in the README).
- Verb in the surface list of THE RULE; target resolved (missing → `session not found`; accepted
  for shape, the ACTIVE surface is searched — agwinterm's v1); `action == "close"` → `open = false`,
  reply `closed`; else `open = true`; a non-empty `query` → set, recompute, `cur = 0`, scroll to it;
  else `next`/`prev` → `cur = (cur ± 1 + n) % n`, scroll; else recompute + scroll; reply
  `SearchStatus`: `n == 0 ? (query.empty() ? "" : "no matches") : "<cur+1> of <n>"`.
- Scroll-to-match: on the main screen `scrollOff = clamp(historyCount - absRow, 0, historyCount)`
  when the match is above the view (or below it: 0) — through P7's `viewOff`/`scrollSurface`, which
  refuse on the alt screen (THE PIN).
- Paint: in `paintPane`, after the selection band, for each match on a visible row invert (or use a
  distinct brush — say which) the `len` cells; the current match gets the selection's brush.
- Status part 2: `FIND <status>` while `open` (`FIND no matches` / `FIND 2 of 7`).

### Task 7: tests

Per Testing Strategy: `control-honesty.ps1` P9 block; `restore-matrix.ps1` cells (replay ×3, `G`
round-trip); `control-read.ps1` (`restoreCommands`, `splitRatios`); `qa/control-honesty.md` and a
new `qa/driving.md` with the human-readable statement of THE GATE and the replay rule.

### Task 8: docs

- Skill text: the NOT list loses `session search`, `session readonly`, `session bind`, `session
  restore`; `session background` stays with "(lite draws no images)"; a "Driving a pane" paragraph
  (readonly first: "stop a human's keys reaching your shell: `session readonly on`; your own
  `session type` still works"), restore/bind ("`session restore` pins a command typed after a
  restart; `session bind claude` replays `claude` instead"), resize, switch, search — agwinterm
  `AgentSkill.cs`'s wording where it fits.
- README `:69-130`: the verb count; a bullet per verb; the status-bar words (`READ-ONLY`, `FIND`);
  the keys paragraph (`Key_ReadOnly`, unbound).
- `docs/state-file.md`: rows `R`, `B`, `G` with the downgrade sentences; the growth rule unchanged.
- This plan: Task 0 findings, round records.
- For the agwinterm docs PR after merge: `docs/lite-parity.md` "Reading and driving a pane" (:35-39)
  rewritten; differences (j)–(s); the batch index P9 → shipped; agwinterm follow-up issues:
  `session.readonly`/`search`/`switch`/`background` `ok:true` on no session and on an unknown op
  (difference (j)/(k)), `session.paste` answering `pasted` on a read-only pane (r), `session.resize`
  ignoring a string `ratio` (m), `session.bind` lower-casing the agent (s).

### Task 9: [Final] verify acceptance criteria

- `./build.ps1` clean; `test/run-all.ps1 -Strict` green under the token (held through teardown;
  released `--cleanup-confirmed` only on a proven teardown); `tools/check-contract.ps1` green; `git
  status` shows no `.ralphex/`/`.revmux/`.
- revmux rounds until a round has no Major/Critical; each fix commit gets its own narrow round; round
  records in this plan. Mail Claude (`claude-agwinterm`) the review-request with the hash when round 1
  starts and every fix hash after; fold his findings; the merge needs both agents' explicit "agree".
- PR against `main` (draft until #45 and P7 merge and the rebase is clean) with the live evidence:
  the honesty transcript's P9 block, the three restart cells, a `PrintWindow` of `READ-ONLY` and of
  a search band.

## Technical Details

### Execution checkpoint — 2026-09-08

- Initial implementations of all six verbs are present; acceptance is not complete.
- Build succeeds on the initial baseline. `test/driving.unit.ps1`: 16/16 passed (ASCII,
  Cyrillic, CJK, astral casing/endpoints, stale cell proof, lossless R/B command encoding).
- Added an API/posted-character P9 block in `control-honesty` through `driving-cases.ps1`;
  parsed successfully, not yet run. Mouse/popup/clipboard/pixel, all-history/alt-screen and
  restart cases still need implementation/completion before readiness; see `qa/driving.md`.
- Shared interactive tests remain blocked on the pre-existing host's ownership and Claude's
  #48 cleanup correction. No P9 host/GUI/clipboard/registry tests have been launched.
- P6 and contract #256 have merged; the old-baseline contract check correctly reports the
  missing P6 selection floor. Dependency rebase, P7 integration and required CI remain gates.
- Search uses Windows invariant scalar casing (the C-locale `towlower` misses Cyrillic).
  Match frames preserve selection inversion: cyan current, amber other, full-row cell proof.
  Pin/binding logs deliberately omit command contents, following lite's logging policy.

- **Why THE GATE lives in `sendBytes`, not in the key handler.** Every human key path — `OnChar`, the
  control-key encodings in `handleKeyDown`, the popup's `WM_CHAR` — ends in `sendBytes`; one test
  there is the whole rule for keys, and the two paste paths are the only other writers a human
  reaches. `session type` writes `ovIo` directly and is not gated BY DESIGN (an agent turns a pane
  read-only to keep the human out, then keeps driving it).
- **Why `session paste` refuses instead of mirroring agwinterm.** agwinterm's `PasteTextInto` returns
  silently and the verb still answers `pasted` — the caller cannot tell. Lite's honesty rule (P2):
  a reply names what happened. The refusal names the pane and says `nothing pasted`.
- **Why the pin and the binding are two state lines, not one.** They are two verbs with two
  lifetimes (a binding is an agent's, a pin is the user's); one line with four fields would make a
  clear of either rewrite the other's bytes. `K`'s shape, twice.
- **Why the ratio is slot 0's share.** `slotRect` thinks in slots; a swap moves shells between slots
  and the divider stays where it was (agwinterm: `Ratio` is on the pane, and `SwapPanes` swaps the
  panes' ratios with them — CHECK `Program.Sessions.cs`'s swap: if agwinterm's divider moves on a
  swap, lite must do the same; record which).
- **Why search does not recompute on output.** Lite's paint runs from `WM_PAINT`; a recompute per
  output chunk on a busy shell would scan the whole history per frame. The verb recomputes; the
  README says "matches are as of the last `session search` call".
- **Timer ids**: 1 caret, 2 relayout, 3 P7's autoscroll, 4 replay.
- **Task 0 findings (Codex, 2026-09-08):** worktree starts at `320a0cf`; P6/P7 rebase
  remains a readiness gate. `selectPrimary` is the displayed-session selection seam; initial
  restoration and close/remap also write pane indices. P7's mark-mode hooks must be reconciled
  at rebase. `SwapPanes` in agwinterm exchanges ratios along with the panes, preserving the
  sequence of shares: lite's ratio belongs to slot 0, not to the shell.
  `MruWalk` implicitly starts a walk and immediately advances, as Task 5 requests.
  `FfiCell.rune` already contains a Unicode scalar, not a UTF-16 code unit; search must not
  interpret a scalar as a surrogate pair. Query UTF-16 still needs scalar decoding.
  `Session` objects and data handles are retained after unlisting for the reader; there is no
  `CloseHandle(s->data)` in this revision. Replay resolves a listed, live pane by immutable
  pane id and snapshots the handle under the lock. It must never hold that lock across `ovIo`.

  | `ovIo` site on `320a0cf` | Class | Read-only behavior |
  | --- | --- | --- |
  | declaration/implementation | transport | no global gate |
  | `runHostActions`, Respond | internal terminal reply | allowed |
  | reader loop, `write=false` | output | allowed |
  | `sendBytes` | human keys, frame and popup | blocked |
  | `pasteClipboard`, bracket prefix/text/suffix | human paste | blocked before clipboard access |
  | `mouseReport` (P7: `mouseReportSurface`) | human reporting | swallowed; non-reporting selection/scroll unchanged |
  | `session.type` | API input | allowed |
  | `session.paste`, bracket prefix/text/suffix | API paste | explicit refusal before clipboard access |
  | P9 replay timer (new) | internal replay | allowed |

  `session.write` feeds the emulator, not `ovIo`, and remains allowed. A blocked human
  Esc/Ctrl+C must also avoid clearing a working agent status: no interrupt was delivered.
  Explicit shell ids must remain distinct from the shell's overlay under the P5 rule; the
  Task 1 `surfaceOf(target)` pseudocode correction was sent to Claude in mail `8596`.

  R/B command fields use JSON string-content escapes inside their TSV fields (same role/index
  shape as K). Unlike K's lossy `tsvField`, this preserves literal backslashes, tabs/newlines
  and quotes in commands replayed verbatim. Invalid encoded fields are dropped with a log.
  No persisted read-only flag and no replay of captured K commands are added.

  Review stopping rule: Boris's direct 2026-09-08 delegated workflow supersedes the older
  per-fix broad-round wording above. Full review + Claude review, batched fixes and one focused
  confirmation normally suffice; extra rounds need an actual blocker/substantive change.

## Post-Completion

- agwinterm docs PR: `docs/lite-parity.md`, the batch index P9 shipped, differences (j)–(r).
- agwinterm follow-up issues per Task 8.
- Contract (decision 13): P9 adds no step to `tests/conformance/control-api.json` — its header says
  `search, readonly, bind, background` are "deliberately NOT" the shared floor, and changing that is
  an agwinterm PR with the lite `check-contract -Update` dance behind it. A contract PR adding
  `session.readonly` (`on`/`state`/`off` + the unknown-op refusal once agwinterm refuses too),
  `session.restore` (the three refusals + `pinned`/`cleared`) and `session.resize`'s refusals is the
  natural next contract batch, after P9 merges in lite and the agwinterm follow-ups land.
- P10-lite carries: `restore-commands` (then `replayOnRestore` may become true), a find bar/Ctrl+F,
  divider drag, `session background` if wanted.
- Release: lite 0.17.x after merge (Boris tags).

## Codex takeover execution — 2026-09-08

- P9 rebased onto P7 candidate `04a31d0` (PR #50): `304a860` implementation, `bb5dbb4` fix batch.
  The rebase preserves both timers, mark/select/read-only bindings, status segments and the
  lock-free mouse I/O correction. Build, canonical contract check and 30 pure driving checks pass.
- Prior Claude findings and Codex recovery review (4/4 healthy, one Major/nine Minors) are batched:
  previews no longer reorder MRU; cancel preserves recency; exited origins start before the first
  live entry and can be restored by cancel; closed IDs are removed; default names count within
  workspaces. Alt search excludes main history. Ratios override valid grow arguments, zero wrong-axis
  growth is a no-op, unavailable geometry refuses before mutation, and promotion preserves ratio.
  Read-only Backspace/Shift-Tab preserve scrollback. Saved R/B commands use strict escape/Unicode
  decoding; malformed fields are rejected instead of silently changing a command that may replay.
  Runtime comments/state-file ordering and stale plan pseudocode are corrected in the same batch.
- Added guarded live acceptance through the P7 fixture, not through the legacy text-only clipboard
  helpers. Initial complete run: 83 checks (token 46). Expanded acceptance: 117/117 passed
  (`selection-ui-20260908T131511-e953dc`, token 50). Both tokens were released on verified cleanup.
  The raw-key sink enables VT input and reads raw bytes: ReadKey alone cannot prove delivery of
  reporting mouse input. Static pixels wait for an idle sink, and each replay command owns a
  separate marker file. Popup dismissal is observed before closing its owner. All earlier fixture
  failures are retained, not relabelled as passes. A final input-gate consolidation now also keeps
  readonly arrows/plain characters from resetting scrollback; combined P7/P9 rerun and narrow
  confirmation are pending for that final candidate.
- Full Strict suite remains a merge gate on the disposable GitHub Windows runner. Some legacy
  fixtures still have unsafe shared-desktop clipboard/registry handling; they are not run locally.
  The owned P7/P9 guarded fixture remains mandatory for local acceptance and token release proof.
