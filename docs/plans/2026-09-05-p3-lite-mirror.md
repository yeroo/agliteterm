# P3-lite — persistence, the agliteterm half

The agliteterm half of batch **P3** of the parity programme (agwinterm
`docs/plans/2026-09-03-parity-batches.md`). agwinterm shipped its half as PR #233 on 2026-09-05
(plan: agwinterm `docs/plans/completed/2026-09-05-p3-persistence.md`, with two revmux rounds of
findings — read it first; every rule below was made there and lite copies it, it does not
re-decide it), followed by the contract PR #235. `tools/check-contract.ps1` is red on `main` right
now for exactly the three steps and two refusals this batch adds; that is the gate, and it goes
green when this merges.

Two verbs. `session.context` is the mirror the batch index always promised (a `C` line type, the way
`P` arrived). `restore.capture` is the heavier half: lite has **no** captured-command slot, no
restore-commands toggle and no command replay at restart — it restores a session's LAUNCH spec (the
`S` line's app/cwd/args) and nothing about what was running inside. This batch lands the slot, its
persistence and the verb; the replay stays with `session.restore` in **P9**, and the reply says so
rather than pretending.

## Overview

- **`session.context <text> | --clear [--target ID]`** — one line of free text per session. The
  rules are agwinterm's `SessionContexts` exactly, not approximately, with the same refusal
  wording: trim; blank refused (naming `--clear` as the way to remove one); any character below
  U+0020 or in U+007F..U+009F refused naming its offset; more than **200** characters refused naming
  the ceiling; text beside `--clear` refused. Reply `{"session":"<id>","context":"<text>"|null}`
  with the value **in effect** after the write. Shown **dimmed after the name in the sidebar row**;
  carried by `tree --json` as `"context"` on the session node, emitted **only when set**; persisted
  as a **`C` line** after the `S` lines; survives undo-close (Ctrl+Shift+T). A rename leaves it
  alone. Lite's window caption is instance-named and has never carried a session name, so there is
  no title-bar surface here — recorded in `lite-parity`, not invented.
- **`restore capture [--target ID]`** — capture the foreground command of every real pane (or of
  the one named) into a durable per-pane slot NOW, save, and report per pane. Reply
  `{"captured":<n>,"replayOnRestore":false,"panes":[{"pane","session","captured":string|null}]}`.
  `null` is "the shell had no non-denylisted child" and is written too (a fresh capture replaces an
  older checkpoint, including to nothing). Refusals, each with nothing written for anyone: an
  unknown target (the verb's own wording, naming the target); a present-but-empty target; a
  quick/scratch/overlay cover (never restored, so no slot); a process query that did not run. The
  slots read back from `tree --json` as `capturedCommands` on the owning session node, keyed by
  pane id (the session id for pane 0, the split's id for pane 1); persisted as a **`K` line**.
  **`replayOnRestore` is always `false`** in lite — see Technical Details.

Both replies are objects (`ctlOk(rawJson)`); lite's session verbs answered bare strings until now.

## Context (from discovery)

- `src/main.cpp:325` `struct Session` — `id`, `std::wstring name` (empty = "session N", computed
  at draw time `:4364`), `ws`, `splitId` (pane 1's session id), `flagged`, `hidden` (split, quick,
  scratch, overlay shells), `app/cwd/args` (the launch spec), **`DWORD childPid`** (`:348`, set from
  the pty-host attach reply at `:2100` — every session already has its shell pid; no protocol
  change, as P3 claimed). `childPid` is never refreshed and is 0 for a restore placeholder.
- Dispatcher `ctlDispatch` `:6879` (if-chain, control-pipe thread); the target is resolved ONCE at
  `:7051` by `resolveTarget` (`:6466`: empty/`active` → focused; exact id, id prefix ≥ 4, then
  case-insensitive exact NAME among non-hidden sessions, ambiguity refused). `session.rename`
  `:7326-7335` (`ctlOkStr("renamed")`; `target->name = widen(tsvField(nm))` under `LockG`; posts
  `WM_APP_REFRESHTREE`). `tree --json` `:6889-6928` (string-built under one `LockG`; session node
  `id, name, active, status, statusChangedAt, flagged, exited, failed, unread, cols, rows` — the
  booleans are always emitted; hidden sessions skipped at `:6903`).
- JSON reader `src/control.h` (`JsonReq::get` returns `""` for absent AND empty — presence is
  `req.fields.find("args.context")`, the P2-lite trick at `:7216`; `--clear` arrives as the raw
  text `true`; `jsonParseString` decodes `\t` `\n` `\uXXXX`, so a control character reaches the
  dispatcher intact and the offset is measured in the DECODED string). Replies `ctlOk` /
  `ctlOkStr` / `ctlErr`.
- Validation precedents, inline per verb, no shared helper: `--size-percent` `:7215-7226`,
  `sidebar width` `:7555-7580`, `session.type`'s control-byte refusal `:7084`.
- **Sidebar** is a native `SysTreeView32` (`g_tree` `:464`). Labels built in `refreshTree()` `:4316`
  (UI-thread-only, enforced at `:4323` — other threads post `WM_APP_REFRESHTREE`); label at
  `:4364-4367` (name, then ` (exited)` / ` (working…)` suffixes). `NM_CUSTOMDRAW`:
  `CDDS_ITEMPREPAINT` `:6183-6206` sets ONE colour/font for the row; **`CDDS_ITEMPOSTPAINT`
  `:6208-6248` draws the flag pennant at `rr.right - 15` and the unread pill at `rr.right - 20 - w`**
  — the post-paint pass is where a dimmed run after the label goes (`TVM_GETITEMRECT` with
  `wParam = TRUE` gives the text rect).
- Undo-close: `struct ClosedSpec { name; ws; app; cwd; args; }` `:2179`, pushed in `closeSessionAt`
  `:2200`, consumed by `reopenClosed()` `:2253` (`s->name = sp.name` at `:2259`). No control verb —
  Ctrl+Shift+T / `IDM_REOPEN` only.
- **State file** `sessions.tsv` (`stateFilePath()` `:2555`; `.tmp` then rename; `.bak`).
  `tsvField()` `:2662` replaces `\t` `\n` `\r` with a space. `saveSessionState()` `:2675` writes
  `V1`, `W` per workspace, `S\t<ws>\t<name>\t<app>\t<cwd>[\t<arg>…]` per non-hidden session
  (`savedOrder` records S-line order, `:2703`), `F` (flagged indices), `D` (host ids in S order),
  `P\t<ownerIdx>\t<app>\t<cwd>[\t<arg>…]` per split (`:2725`), `A`. It takes `g_lock` itself
  (`:2686`) and releases it before the I/O (`:2732`); callers today: the UI thread's refresh
  (`:4393`) and the quit path (`:6416`) — never a pipe thread.
  Reader `parseStateFile()` `:7812`: dispatch on `ff[0]`; the rule at `:7830-7833` ("the format
  grows by ADDING line types … unknown line types are ignored"); **the `P` count-mismatch guard
  `:7866-7871`** (refuse every `P` line wholesale when `sLines != specs.size()`, `logWarn` naming
  both counts) and the same for `D` `:7872-7876`. Load-time validation precedents: the registry
  loaders `:2454-2462`, `activeWs` clamp `:8071`.
- Locks: `g_lock` (`LockG` `:997`); `g_resizeLock` (rule at `:988`: never acquired while `g_lock`
  is held); `g_reqLock` (pty-host pipe, #27); `g_statusLock`; `g_evtLock`. The P2-lite rules: no
  cross-thread `SendMessage`, workers POST `WM_APP_REFRESHTREE`. The two verb shapes:
  `session.overlay` (`:7196`, validate then post a heap `OverlayReq`, refuse on a failed post) and
  **`sidebar width` (`:7555-7590`: the pipe thread writes the state itself, posts the relayout, and
  answers from what it wrote — the closer analogue for `restore.capture`)**. Lite has NO
  `InvokeOnUiQueued`; a synchronous hop is what `refreshTree`'s guard forbids.
- Process queries: exactly one today, `processCwd(DWORD pid)` `:2572` —
  `NtQueryInformationProcess` + `ReadProcessMemory` at `PebBaseAddress + 0x20` →
  `RTL_USER_PROCESS_PARAMETERS`, `+0x38` `CurrentDirectory.DosPath`. **`CommandLine` is the
  `UNICODE_STRING` at `+0x70` of the same struct on x64.** No `CreateToolhelp32Snapshot`, no
  `GetProcessTimes`, no WMI, no spawned powershell anywhere in lite.
- Pane ids: a split is a real hidden `Session` and `session.split` returns its id (`:7378`); the
  first pane IS the session. Cover panes (quick, scratch, overlay) are hidden too; the only
  discriminator is "some visible session's `splitId` equals this id" (`closeSessionAt` `:2199`
  does that walk). Hidden sessions are excluded from `tree` and from the save (`:2698`).
- Tests: `test/control-honesty.ps1` (P2-lite's — the shape to copy: every refusal asserted twice,
  reply and world; every oracle proved non-vacuous first; raw JSON lines to the pipe to pin the
  server-side decoder), `test/conformance.ps1` + `test/control-api.json` (agwinterm's; 46/7 vs
  49/9 today), `test/restore-matrix.ps1` (`Cell` `:129`, `-Kill` `:133`, `Signature` `:100`,
  `Seed-State` exact bytes; **never run with a real lite window open** — the pty-host pipe is keyed
  on the app id), `test/run-all.ps1 -Strict`, `tools/check-contract.ps1`, `tools/fetch-native.ps1`.
  The SKIP probe pattern: a CLIENT-side refusal string probed with no pipe open
  (`sidebar width wide` → `whole number`); `-Strict` fails on a skip.
- agwinterm reference: `src/Agwinterm.Pty/SessionContexts.cs` (rules + wording), `RestoreCaptureReply.cs`
  (reply builder + `UnknownTarget` / `EmptyTarget` / `CoverPane` / `QueryFailed` wording),
  `ControlServer.cs` `HandleSessionContext` / `HandleRestoreCapture`, `Program.ControlHost.cs`
  `RestoreCapture` (snapshot under lock → query with no lock → one write + one save),
  `Program.Services.cs:1244` the default denylist (`powershell pwsh cmd conhost wsl ssh bash
  oh-my-posh git windowsterminal`), `tests/conformance/control-api.json` the P3 steps. agwinterm
  #234 lists the r2 leftovers — read it so lite does not copy them (the `--target true` value
  comparison; the interface's stale `""` sentence).

## Constraints

- **`test/control-api.json` = agwinterm's, byte for byte** (`tools/check-contract.ps1 -Update`);
  the three P3 steps and two errors must pass on lite before this merges.
- **The refusal wording is agwinterm's, verbatim.** One API, one answer. Copy the strings from
  `SessionContexts.cs` and `RestoreCaptureReply.cs`; do not paraphrase.
- **Additive line types only** (`C`, `K`), after the `S` block, indexed by S-line position, refused
  wholesale on a count mismatch with the `P` guard's wording, ignored by an older reader. Every
  loaded value validated through the same rules the verb applies; a stored context that fails is
  dropped on load, not drawn, `logWarn`ed once.
- **Nothing in this batch touches `HKCU\Software\agliteterm`** — per-session state lives in
  `sessions.tsv` only; the registry is shared across every sandbox and the user's real app.
- **Locking rules stand**: no `g_lock` across a cross-thread `SendMessage`; `g_lock` not held while
  acquiring `g_resizeLock`; the process query runs with NO lock held; every write of a `Session`
  field from the pipe thread is under `LockG` and re-checks the pointer is still in `g_sessions`
  (#21 is the open defect class — do not add to it). No `keybd_event`/`SendInput` in tests.
- **No pty-host protocol or ABI change** (`kRequiredAbi` stays 18; `childPid` is already there).
- **Refusals leave the world untouched**: a refused context leaves the old one; a refused capture
  writes nothing for anyone and saves nothing.
- Cross-cutting safety rules from `qa/product.md`: sandbox instance (`--pipe`), never the user's
  real app, never `--no-restore` against real data; the restore-matrix rule about no live lite
  window during a run.

## Testing Strategy

- **`test/control-honesty.ps1`** gains a P3 block (SKIP when the CLI predates P3, probed
  client-side: `agwintermctl restore` with no sub-verb answers the usage line, a pre-P3 client
  answers `unknown command`): set / read-back / every refusal twice (reply, then the world via
  `tree --json` and the state file) / clear / rename-leaves-context / hidden-pane refusal /
  capture reply shape / capture read-back / `K` line in the file / re-capture of nothing writes
  null / unknown, empty and cover targets touch no slot / a raw-JSON `{"target":""}` to the pipe.
- **`test/restore-matrix.ps1`** gains cells: context survives a graceful restart and a `-Kill`
  restart; the captured slot survives both; a seeded `C` line with a control character is dropped
  on load (session restored, context absent, one `logWarn`); a seeded `C` count mismatch is refused
  wholesale (every session restored, no context, the guard's warning); a pre-P3 file (no `C`/`K`)
  restores unchanged; a `K` line for a session with a split restores both slots.
- **`test/conformance.ps1 -Strict`** with the updated contract; `tools/check-contract.ps1` green.
- A sidebar capture (`PrintWindow`) in `qa/persistence.md` showing the dimmed run after the name,
  and that the pennant / unread pill did not move.
- `test/run-all.ps1 -Strict` green before the PR; the 80-session `test/stress.ps1` run ALONE
  afterwards (it crashed once when run beside a build).

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope

## Implementation Steps

### Task 1: `session.context` — rules, verb, tree, undo-close
- [x] `Session` gains `std::wstring context;` beside `name` (`main.cpp:325`); `ClosedSpec` gains
      `context` and `reopenClosed` restores it (`:2179`, `:2259`)
- [x] a small validator beside the verb — `contextRefusal(const std::string& decoded, std::string*
      normalized)` — implementing the four rules with agwinterm's exact wording from
      `SessionContexts.cs` (`MaxLength` 200 with its "display budget, not a storage limit" comment;
      the control-character refusal names the OFFSET in the decoded string; blank names `--clear`;
      trim both ends). Used by the verb AND by the state-file loader
- [x] `session.context` in `ctlDispatch` beside `session.rename`: presence via
      `req.fields.find("args.context")`, `--clear` via `args.clear == "true"`, text+clear refused
      with agwinterm's `TextAndClear`; unknown target → `SessionContexts.NoSession` wording (`session
      not found; nothing changed`) — resolution is `resolveTarget`'s, the same as rename; **a hidden
      session (split, quick, scratch, overlay) is refused** — it has no row, no `S` line and no
      `C` slot, so accepting would lose the value silently (wording: the cover refusal's spirit,
      naming the id); write under `LockG` (re-check the pointer is in `g_sessions`), post
      `WM_APP_REFRESHTREE`, reply `ctlOk` with `{"session":…,"context":…|null}` read back from the
      session under the same hold — the value in effect
- [x] `tree --json` (`:6906-6919`) emits `"context":"…"` **only when set** — a comment saying this
      is deliberately the agwinterm rule (`ControlServer.cs:431`), unlike lite's always-emitted
      booleans, because a script tests presence
- [x] `session rename` is untouched except that its comment states the two fields are separate
- [x] build; `agwintermctl session context` round-trips against a sandbox before task 2
- ➕ [x] `test/control-honesty.ps1` P3 block, session.context half (35 checks: set / read-back / trim /
      200 accepted / every refusal twice with agwinterm's verbatim wording, incl. raw-JSON lines for
      `""`, a decoded tab, a decoded U+0001, a trailing NEL, a UTF-16 offset after a surrogate pair, text+clear /
      clear / rename-leaves-context / split-shell refusal), SKIP on a pre-P3 client (`restore` probe).
      The capture half lands with task 5. Green under `-Strict` with the dev `agwintermctl`
- ➕ [x] pre-existing suite race fixed on the way: the mid-drag `sidebar width` setup posted the first
      WM_MOUSEMOVE straight after WM_LBUTTONDOWN, and SetCapture's synthetic move (at the PHYSICAL
      cursor) overwrote it — the tree landed wherever the real mouse sat over the window (441 here).
      A 300 ms pause after the button-down lets the synthetic move land first; the drag's later
      checks were already passing

### Task 2: the dimmed run in the sidebar row
- [x] `refreshTree()` leaves the LABEL as the name (the context is not part of the label string —
      a same-colour suffix would be "shown", not "shown dimmed", and it would enter the treeview's
      own hit-testing/rename EDIT width); in `CDDS_ITEMPOSTPAINT` (`:6208-6248`), for a session
      item with a context: get the text rect (`TVM_GETITEMRECT`, `wParam = TRUE`), draw ` — <context>`
      (or the context alone with an 8 px gap) in the theme's dim colour with the tree font, starting
      at `text.right + gap`, clipped to `min(rr.right - 20 - unreadPillW - 6, …)` so the pennant and
      the pill never move and never overlap it; `DT_END_ELLIPSIS | DT_SINGLELINE | DT_VCENTER |
      DT_NOPREFIX` — the context alone after an 8 px gap (no dash); the flag/unread/context values
      are copied under `LockG` (recursive, so a paint inside a hold is fine) and drawn unlocked; the
      clip edge is `rr.right - pillInset - pillW - reserve` with the pill measured FIRST, and the
      same edge when there is no pill (which also clears the pennant), so the run ends at one x
      whether or not the badges are there
- [x] the dim colour and the gap are named constants beside the badge constants; `ItemPrepaint`'s
      `CDRF_NOTIFYPOSTPAINT` already fires for every item — confirm, and confirm the row height does
      not change — `kTreePennantInset` 15, `kTreePillInset` 20, `kTreeContextGap` 8,
      `kTreeContextReserve` 6 (new, beside `kSidebarW`; the two badge insets were bare numbers).
      The colour is the theme's `dim` field (light 110, dark 150, classic `COLOR_GRAYTEXT`) — named
      per theme rather than one constant, so it follows the palette like every other secondary
      text. **Confirmed NOT the case**: the post-paint notification was requested only for flagged or
      unread rows (`:6215`), so a context-only row drew nothing (the fixture's first run: "captures
      identical" for `gamma`); the gate now includes a non-empty context. Row height unchanged: the
      three rows are 18 px apart in both captures, nothing sets the item height
- [x] the working/exited suffixes still come first (they are part of the label); the context sits
      after whatever the label is — the run starts at the TEXT rect's right (`TVM_GETITEMRECT`,
      `TRUE`), which is where the tree drew the whole label, suffix included
- [x] a sandbox `PrintWindow` capture with a context set, attached to the task note, and the
      `qa/persistence.md` case for it (format as `qa/control-honesty.md`) —
      `docs/img/qa-p3-context-row.png` (alpha flagged + unread 1 + `reviewing the P3 diff`; gamma a
      96-char context cut with `…`; beta plain), driven by `qa/fixtures/context-row.ps1`: the
      before/after diff bbox lay inside the two rows to the right of their labels, the amber and
      red badge pixel counts were identical (41 / 183) in both captures. `qa/persistence.md` written
      with this case; the restart case is task 6's

### Task 3: the `C` line — persistence, validated on load, restart cells
- [ ] `saveSessionState()` (`:2675`): after the `S` block, inside the same walk that fills
      `savedOrder`, one `C\t<idx>\t<tsvField(context)>` line per session WITH a context (no line for
      none — an empty-field form would be ambiguous). Placed with `F`/`D`, before `P`, and the
      comment states the additive-line-type rule and that an older build ignores `C` and restores
      the sessions without contexts (and drops them on its next save — write-back loss, the same
      exposure agwinterm documented)
- [ ] `parseStateFile()` (`:7812`): a `C` arm (`≥ 3` fields; idx + text into
      `ps.contexts[idx]`); after the loop the **same count-mismatch guard as `P`** (`:7866`) — a `C`
      set is refused wholesale when `sLines != specs.size()`, with the guard's wording adapted
      (`… refusing %zu context line(s) rather than attaching them to the wrong sessions`); an
      out-of-range idx is dropped with a `logWarn`
- [ ] `restoreSessions()`: each context runs through the Task 1 validator on load; a failing value
      is dropped with one `logWarn` naming the session and the rule (not drawn, not re-saved); a
      passing one is set before the first `refreshTree`
- [ ] `test/restore-matrix.ps1` cells (`Cell` `:129`): `context-graceful`, `context-killed`
      (`-Kill`), `context-bad-line` (seeded `C` with a `\x01` — restored session, no context, the
      warning in the log), `context-count-mismatch` (seeded `C` for a session count that disagrees
      — every session restored, no context, the guard's warning), `pre-p3-file` (no `C`/`K` —
      unchanged restore). Signatures extended to include the context so the assertion is on the
      world, not the reply
- [ ] run `restore-matrix -Strict` before task 4

### Task 4: the capture path — children, command lines, newest, denylist
- [ ] a new query beside `processCwd` (`:2572`): `captureForeground(const std::vector<DWORD>& shellPids,
      std::map<DWORD,std::string>* out) -> bool` — ONE `CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS)`;
      for each entry whose `th32ParentProcessID` is a shell pid: `OpenProcess` (`PROCESS_QUERY_LIMITED_INFORMATION
      | PROCESS_VM_READ`), `GetProcessTimes` for the creation time, the command line via the PEB
      read lite already does (`RTL_USER_PROCESS_PARAMETERS.CommandLine` at `+0x70`), the exe name
      from `szExeFile`; per shell pid keep the NEWEST non-denylisted child. Returns **false only when
      the snapshot itself failed** (that is `QueryFailed`); a child that cannot be opened or read
      (elevated, protected) is skipped exactly as agwinterm skips a CIM row with no command line —
      say so in the comment. No lock held, no UI, milliseconds, no timeout needed (no child process
      is spawned — the reason lite does not port the CIM query; `docs/lite-parity.md:158`)
- [ ] the denylist is agwinterm's DEFAULT list as a constant (`powershell pwsh cmd conhost wsl ssh
      bash oh-my-posh git windowsterminal`, matched on the exe name without extension, case-
      insensitive); lite has no config file, so there is no `restore-denylist.conf` — the comment
      says where agwinterm's lives and that lite's is the same list frozen
- [ ] `Session` gains `std::string capturedCmd;` (pane 0 = the session itself; a split shell is its
      own `Session` and carries its own)
- [ ] build; a throwaway `main.cpp` log line or the honesty suite proves the query finds a `ping -n
      300 127.0.0.1` child of a sandbox pane's shell before task 5

### Task 5: `restore.capture` — the verb, the `K` line, the read-back
- [ ] `restore.capture` in `ctlDispatch`: **snapshot** under `LockG` — for a bare call every
      non-hidden session plus each one's `splitId` shell (the panes `P` lines restore), as
      `(Session*, ownerId, paneId, childPid)`; `--target`: `resolveTarget`; an unknown target →
      agwinterm's `UnknownTarget(target)` wording; a hidden session that no visible session's
      `splitId` names (quick/scratch/overlay) → `CoverPane(id)` wording; a present-but-empty target
      (`req.fields.find("target")` found and empty — the CLI refuses it too, so also pin it with a
      raw JSON line) → `EmptyTarget` wording. Every refusal returns before the query
- [ ] **query** with no lock held (`captureForeground`); `false` → `QueryFailed` wording, nothing
      written
- [ ] **write** under `LockG`: for each snapshot entry still in `g_sessions`, `capturedCmd = found
      ? cmd : ""` (null written too — a fresh capture replaces an older checkpoint); entries closed
      since the snapshot are dropped from the reply, not written; build `panes[]` from what landed
- [ ] **save from the pipe thread**: call `saveSessionState()` directly after the write so the reply
      describes a state that is on disk (agwinterm's rule). `saveSessionState` gets a
      `g_saveLock` (a CS around the `.tmp` write + rename only, acquired AFTER `g_lock` is
      released — state the ordering in the comment) so a pipe-thread save cannot collide with the
      UI thread's; then post `WM_APP_REFRESHTREE` for the tree. This is the first pipe-thread save —
      the comment says so and why
- [ ] reply `ctlOk` with agwinterm's shape: `captured` = the non-null count, `replayOnRestore`
      **`false`**, `panes` in snapshot order with `pane`, `session` (the owner's id), `captured`
      string or `null`
- [ ] the `K` line: `K\t<idx>\t<pane0>\t<pane1>` per session with at least one captured command
      (`tsvField` on each; empty = none; pane 1 = the `splitId` shell's slot, or empty when no
      split), with the `P` count guard on load and the same additive comment; `restoreSessions`
      loads pane 0's slot onto the session and pane 1's onto the split it creates from the `P`
      line (both are re-created, so the slot lands on the new `Session`). A slot is a STRING with
      no rules beyond `tsvField` — nothing to validate on load except the index
- [ ] `tree --json`: `"capturedCommands":{"<paneId>":"<cmd>",…}` on the owning session node,
      emitted only when any pane of that session has one — `AppendPaneMap`'s shape
      (`ControlServer.cs:470`); the split's id appears as a key even though lite's tree has no
      split node (comment: that is where the pane-id read-back lives until P9 adds `paneIds`)
- [ ] `restore capture` with no `restore` sub-verb / unknown sub-verb: the CLI already answers the
      usage line client-side — nothing to do server-side beyond `restore.capture`; `restore.clear`
      stays unimplemented (P9) and an unknown `cmd` keeps lite's existing refusal
- [ ] `test/control-honesty.ps1` P3 block (Testing Strategy above); `test/restore-matrix.ps1`
      cells `capture-graceful`, `capture-killed`, `capture-split` (a `K` line with both fields);
      run both `-Strict` before task 6

### Task 6: docs, contract, trackers
- [ ] `tools/check-contract.ps1 -Update` → `test/control-api.json`; `test/conformance.ps1 -Strict`
      green (49 steps, 9 errors)
- [ ] `README.md` / the control-verb table and the skill text lite ships (wherever `sidebar width`
      was documented in P2-lite): `session context` (rules, `--clear`, the row, the `C` line, the
      restart) and `restore capture` (the reply, `replayOnRestore` **always false in lite and why**,
      the `K` line, no denylist file); `docs/` entry for the state-file format naming `C` and `K`
      beside `P`
- [ ] `qa/persistence.md` (the row capture case; a restart case with the file inspected)
- [ ] agwinterm-side follow-up noted for the sibling docs PR there: `docs/lite-parity.md` P3-lite
      entry → shipped, with the three deliberate divergences (no title-bar surface; `replayOnRestore`
      constant false; hidden-pane context refused)

### Task 7: [Final] Verify acceptance criteria
- [ ] every Overview item implemented, with agwinterm's wording where the plan says verbatim
- [ ] edge cases: a context on a session that is then renamed (both survive a restart); a context
      of exactly 200 accepted, 201 refused; a `` (decoded) refused naming offset 0; a
      context with a non-BMP character (surrogate pair decoded by `jsonParseString`) accepted and
      shown; `restore capture --target` naming a split's id (captures that one pane); naming a
      quick pane (cover refusal); a capture while a pane's child is exiting (null or the command,
      never a crash); two captures back to back; a session closed between snapshot and write
      (dropped from the reply); a seeded `K` line whose pane-1 field names a split that the `P`
      guard refused (slot dropped with the `P` set)
- [ ] `test/run-all.ps1 -Strict` green with the dev `agwintermctl`; against the RELEASED client
      the P3 checks SKIP (not fail) and everything else passes; `tools/check-contract.ps1` green;
      `tools/check-abi.ps1` v18
- [ ] `test/stress.ps1` (80 sessions) run alone, green
- [ ] mark P3-lite shipped in agwinterm's batch index and `docs/lite-parity.md` (in the agwinterm
      docs PR), and in this repo's `docs/` wherever P2-lite recorded itself

## Technical Details

- **Why the row and not the caption.** agterm's item says "title bar and tree". Lite's caption is
  the OS caption, set once to the instance name, and no session name has ever been in it; putting
  one there now is a new behaviour, not a mirror, and it could not be "dimmed". The tree row is
  lite's one per-session text surface, and its post-paint pass already draws two badges after the
  label — the context is the third.
- **Why `replayOnRestore` is a constant `false`.** The field exists so a caller learns whether the
  slot will be typed back on the next start. Lite never types anything back: it restores launch
  specs, not commands, and `session.restore` is P9. Answering `false` is the truth; adding a toggle
  with nothing behind it, or answering `true`, would be the lie P2-lite existed to end. When P9
  lands the replay, the field starts reporting the toggle — the shape does not change.
- **Why the query is in-process.** agwinterm shells out to PowerShell + CIM once for all panes
  (1–15 s, a timeout, a kill on expiry — and two round-1 Majors about exactly that). Lite already
  reads a shell's PEB for its cwd; the command line is 0x38 bytes further along, and Toolhelp32
  gives the parent-pid walk. Milliseconds, no child process, no timeout semantics — and the one
  failure mode (`CreateToolhelp32Snapshot` failing) maps cleanly onto `QueryFailed`.
- **Why a hidden session refuses `session.context`.** `resolveTarget` reaches a split by id. A
  context set on it would be drawn nowhere (no row) and saved nowhere (no `S` line, no `C` slot),
  which is "succeeded, then vanished". Refusing is the same rule as the cover refusal on
  `restore.capture`, and the same rule agwinterm's fake was split for (#228 item 3).
- **Why `C` and `K` are separate line types, one per session that has a value.** A single
  positional line with a field per session would carry an empty field for every session without a
  value, and `tsvField` cannot distinguish "empty" from "absent". One line per session that has
  something, indexed by S position, is exactly the `P` idiom; both get the `P` count guard.
- **Why the pipe thread saves.** agwinterm's reply "describes a state that exists on disk"; lite's
  alternative (post the refresh, which saves) writes the reply before the file, so a kill in that
  window loses a capture the caller was told it had. `saveSessionState` already takes and releases
  `g_lock` itself and does its I/O outside the hold; the one thing it lacked was a guard against
  two savers racing on the same `.tmp` — `g_saveLock`. This widens who may write the state file
  from "the UI thread" to "any thread, serialized", and the comment says so.

## Post-Completion

*Informational — no checkboxes*

- **Release gate.** The suite's P3 checks SKIP with the released `agwintermctl` until agwinterm
  tags the release that carries #233 + #235 (Boris calls the tag); `check-contract` is red on
  `main` from #235's merge until this PR merges — expected, the same rule P1-lite and P2-lite
  followed.
- lite's own release (the installer is 0.17.14 with `main` two feature PRs above it) — Boris calls it.
- #21 (pipe-thread mutation without `g_lock`) and #27 (`request()` has no read deadline) are
  P9-lite; this batch adds two pipe-thread writes, both under `LockG`, and one pipe-thread save,
  under `g_saveLock` — nothing else to that surface.
- The agwinterm side owes a docs PR marking P3-lite shipped in `docs/lite-parity.md` and the batch
  index, recording the three divergences above.
- Review: **revmux**, two rounds minimum, and a narrow round for each fix commit. P2-lite took
  eight rounds and five of them found a Major inside the previous fix; the lock change here
  (`g_saveLock`) does not ship without its own round.
