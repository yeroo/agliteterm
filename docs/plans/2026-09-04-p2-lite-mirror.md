# P2-lite — stop lying to the caller, the agliteterm half

The agliteterm half of batch **P2** of the parity programme (agwinterm
`docs/plans/2026-09-03-parity-batches.md`). agwinterm shipped its half as PR #226 on 2026-09-04
(plan: agwinterm `docs/plans/completed/2026-09-04-p2-honesty.md`, including four revmux rounds of
findings — read it first; every decision below was made there and lite copies it, it does not
re-decide it). Batch by batch, so this lands right behind it.

Two of Boris's own reports from the work laptop ride along, because they are lite bugs in the
same spirit and lite is what he is running: **#23** (a pane collapsing to 2 columns) and **#24**
(the window keeps coming to the front). Both were diagnosed to the line before this plan was
written; the issues carry the mechanism.

## Overview

One defect class, the same as agwinterm's: **a call that answers `ok` while doing something other
than what was asked.** What lite owes, in the order the tasks run:

- **`session.overlay` reads the wrong argument and lies four ways.** It reads `args.size`
  (`src/main.cpp:6562`) while the shared CLI sends **`size-percent`** (agwinterm
  `src/Agwinterm.Ctl/Program.cs:256`), so every `--size-percent N` anyone has ever passed to lite
  was silently ignored and the hard-coded 70 % popup opened. There is no `resize` action — it falls
  through to *open* and replaces the overlay. `open` with no command opens a plain shell. The
  target is never read, so `--target no-such-session` is `ok`. `close` with nothing open says
  `closed`. Every reply is `ctlOkStr`; the verb contains no `ctlErr` at all.
- **`sidebar` toggles on any word it does not know.** `wantOn` (`:6592`) treats anything that is
  not `on`/`off` as "toggle", so `sidebar width`, `sidebar state`, `sidebar show` and a typo all
  **flip the sidebar** and answer `ok`. Worse than agwinterm's pre-P2 `Ok("sidebar")`: lite
  mutates. And there is no width verb: `g_sidebarW` is reachable only by dragging the splitter.
- **A bare `session new` lands wherever the user last clicked.** The explicit-argument half was
  fixed in P1-lite's era (`:6353-6360` says so in its own comment); with no argument `newSession()`
  still reads `g_activeWs` (`:1825`), which fifteen sites rewrite — the tree click (`:5816`), a
  workspace click (`:5822`), the focus toggle (`:5275`), `session.select`/`duplicate` (`:6587`,
  `:6630`), `workspace.new` over the API (`:6764`) — so one agent creating a workspace redirects
  every other agent's next `session new`. This is the report that started Task 5a in agwinterm,
  and it was a **lite** report. Boris chose: the caller's own workspace.
- **`--workspace` beside `--workspace-name`** wins silently for `--workspace` (`:6373`, `:6377`);
  agwinterm refuses the pair.
- **`--stdin` on `session type`** — nothing to do server-side (lite's handler already takes
  `args.text`, folds newlines and refuses control bytes, `:6426-6451`); lite inherits the flag the
  moment its CI fetches a post-#226 `agwintermctl`. What lite owes is a **test through the
  released client** that quotes, newlines and runs of spaces survive lite's own JSON decoder
  (`src/control.h:26-68`), and the docs.
- **#23** — `paneGridSize` floors a negative content rect at `2` (`:1374-1380`), `hostResize`
  latches `s->cols` before the pty-host confirms and ignores `request()`'s result (`:1394-1416`),
  and `g_sidebarW` is never re-clamped against the window (`:5451` drag-only; `:2182` load).
- **#24** — `quick` / `session.scratch` / `session.overlay` / `window.select` and the popup's
  `WM_CLOSE` / `WM_DESTROY` all call `SetForegroundWindow` unguarded (`:5034`, `:5044`, `:5059`,
  `:4987`, `:4998`, `:6859`); no `WS_EX_TOPMOST` exists anywhere, so what Boris sees is repeated
  foreground stealing by an agent loop.

What agwinterm decided, and lite must match (each is a contract, not a style):

- **Out of range is refused, not clamped**, for `--size-percent` and for `sidebar width`. One API,
  one answer to "you asked for something outside the range". The reply still reports the value in
  effect, so a legitimate difference (lite's own minimum) is visible without pretending the
  caller's number was honoured.
- `session.overlay`: `open` with no command → refuse; a **named** target that resolves to no
  session → refuse for `open`, `resize` and `close` alike, one wording; `resize` with no overlay
  open → refuse. `close` stays `ok` ("no overlay") when the session resolves and has no overlay,
  **and** for an untargeted close — the conformance step `session overlay close` runs with nothing
  open and no `--target`, and it must stay green.
- `sidebar`: `on`/`off` are aliases of `show`/`hide`; an unknown op is **refused** and changes
  nothing; `sidebar width` reads, `sidebar width N` sets and replies with the width in effect and
  whether the sidebar is visible; set while hidden is remembered and reported as not applied;
  `sidebar state` carries the width.
- `session.new`: explicit `--workspace` / `--workspace-name` win; else the **caller's** workspace
  (the CLI sends its `AGWINTERM_SESSION_ID` as a top-level `caller` arg, never as `target`);
  else the active workspace, which is the LAST answer. The caller resolves by **id or id-prefix
  only, never by name** (agwinterm's `CallerIsNeverASessionName`). A stale caller falls back, it
  is not refused. `--workspace` with `--workspace-name` is refused before anything is created.
- What is **not** mirrored, deliberately: `session.restore` (lite lacks the verb; P9-lite) and
  therefore `restoreCommands`; agwinterm's overlay `result` action and the overlay id as the
  `open` reply (lite's overlay is created by a posted message, so its id is not known when the
  reply is written — `open` keeps answering the string it does today, and that is written down).

## Context (from discovery)

- `src/main.cpp:6558-6565` — `session.overlay`, the whole verb: `action` (`close` or open),
  `args.command`, `args.size` (wrong key), `g_pendingOverlayCmd` / `g_pendingOverlaySize` under
  `g_lock`, `PostMessageW(g_hwnd, WM_APP_OVERLAY, …)`. `openOverlay` at `:5050-5062`:
  `double f = sizePct > 0 ? min(0.95, sizePct / 100.0) : 0.7;` — the clamp, and the default
  (70 %, a popup window over the main window; NOT agwinterm's "full content region").
  `g_overlayHwnd`, `g_overlaySession` (`:5051` destroys the previous one on open). `OnOverlay`
  `:5627-5632`. The popup's `popupProc` `WM_CLOSE` / `WM_DESTROY` at `:4982-4998`.
- `src/main.cpp:6809-6813` — `sidebar`: `wantOn(req.get("args.op"), cur)`, posts `IDM_TG_SIDEBAR`,
  answers `ctlOkStr("ok")`. `wantOn` lambda `:6592`. `g_sidebarW` `:117` (default `kSidebarW = 180`
  `:114`, `kSidebarMinW = 90` `:116`, `kSplitterW = 5`); drag clamp `:5451`
  (`max(kSidebarMinW, min(c.right * 0.6, pt.x))` then `relayout()`); registry load `:2182`
  (accepts 90..900), save `:2220`; `sidebarSpan()` `:414`; `relayout()` `:423-427` **sends**
  `WM_SIZE` — a cross-thread `SendMessage` if called from a pipe thread, so a setter must POST;
  `OnSize` `:5573-5596` (tree at `g_sidebarW` `:5592`, `syncPaneSizes()` `:5596`). `window.state`
  `:6907-6934` carries `sidebarVisible`, no width. `g_showSidebar`.
- `src/main.cpp:6352-6413` — `session.new`: `wantWs` from `args.workspace` (decimal index only,
  `:6374-6376`, refused when unknown) or `args.workspace-name` (`:6377-6388`, refused when unknown
  without `create-workspace`; created under `LockG` `:6387`); `paneGridSize(g_focus, …)` `:6391`;
  `newSession` `:6403`; `s->ws = wantWs` `:6408`; `selectPrimary` `:6409` — all on the pipe thread
  (`ctlClientThread` `:6970-6982`; issue **#21** owns that, slotted P9-lite — this batch must not
  widen it). `newSession()` defaults `s->ws` from `g_activeWs` at `:1825`. `resolveTarget`
  `:5991-6009`: `""`/`active` → focused; exact id; **id prefix ≥ 4 chars**; then case-insensitive
  NAME (so it cannot be reused verbatim for `caller`). `struct Session::ws` is an index into
  `g_workspaces`, and that index is the workspace id `tree` publishes (`:6343`). Env injection:
  `setEnv(3, "AGWINTERM_SESSION_ID", idbuf); setEnv(4, "AGWINTERM_PANE_ID", idbuf);` `:1728-1742`.
  Request parser `src/control.h:17-24` (`JsonReq::get` returns `""` for absent AND empty; numbers
  arrive as raw text `:105-111`; a quoted `"60"` arrives as `60` — lite cannot see the JSON kind,
  so document that the CLI already refuses non-numbers client-side, agwinterm `Program.cs:249-255`,
  and lite's strict reader rejects anything that is not all digits).
- `src/main.cpp:6426-6451` — `session.type`: `args.text`, `\n`→`\r` fold `:6430`, control-byte
  refusal `:6437-6447` naming byte, index and `--allow-control`. `session.write` `:6452-6465`.
- `src/main.cpp:1362-1372` `paneRect` (no clamp; `contentW` can be ≤ 0); `:1374-1380`
  `paneGridSize` (`max(2L, …)`, no `SIZE_MINIMIZED` guard — `OnSize` has one at `:5574`);
  `:1394-1416` `hostResize` (latch `:1399`, mirror written `:1400-1401`, `request()` ignored
  `:1410`, `emu_resize` under `g_lock` `:1412-1414`); `:1418-1426` `syncPaneSizes` (panes 0/1 only,
  edge-triggered); `:7415` startup rect from the CONSTANT `kSidebarW` while layout uses the
  persisted value. Callers of `hostResize` from pipe threads: `session.select` → `selectPrimary` →
  `syncSplitToPrimary` → `syncPaneSizes`; `session.split` `:6664`; `session.new` `:6391`.
- `src/main.cpp:5026-5047` `togglePopupTerminal` (`SetForegroundWindow` `:5034` dismiss, `:5044`
  show; popup created OWNED by `g_hwnd` `:5019-5020`, so raising it raises the owner);
  `:5050-5062` `openOverlay` (`:5051` DestroyWindow → `WM_DESTROY` → `:4998` raise; `:5059` raise);
  `:4982-4987` popup `WM_CLOSE` raise; `:6857-6860` `window.select`; `:5649-5651` **`HA_BELL`, the
  pattern to copy**: `if (GetForegroundWindow() != m_hWnd) FlashWindow(TRUE);`. Reached from
  `session.scratch` / `quick` `:6676-6682` and `session.overlay` `:6558`. Not verb-reachable (leave
  alone): `:4171`, `:4332`, `:4696`, `:4762`, `:4784`, `:4796`. Dead duplicates of `window.zoom` /
  `window.move` / `window.resize` / `window.state` at `:6944-6963` after the first
  `unknown command` return at `:6960` — the dead `window.state` is the permissive one.
- Locks: `g_lock` `:937` (recursive; `LockG` RAII `:940-945`), `g_statusLock` `:361`, `g_reqLock`
  `:1177` (the pty-host pipe, shared by UI and ctl threads), `g_evtLock`. **Never hold `g_lock`
  across a cross-thread `SendMessage`** (the #20 r4/r5 lesson). Workers post `WM_APP_REFRESHTREE`
  (`:924`) and never call `refreshTree()` directly (`:4038` "UI-thread only").
- Skill: `kSkillMarkdown` `:~6090-6280` (`session type` prose `:6156-6158`; verb table
  `:6244-6250`; the "does NOT have" list `:6259-6266`, which names `session restore` — keep it).
  `README.md:65-68` claims "42 verbs". `installAgentSkill` `:6144`.
- Tests: `test/run-all.ps1` (register a suite by adding its bare name to the single `foreach`
  list; every suite takes `-Exe` and `-Strict`); `test/ui-lib.ps1` (`Resolve-Lite` `:22`,
  `Start-Sandbox` `:154`, `Send-Ctl` `:220`, `Get-CtlResult` `:233`, `Get-PaneText` `:239`;
  **HKCU is not isolated — save and restore anything a case changes**, which a `sidebar width`
  test does: `SidebarW`); `test/ctl-path.ps1` `Get-CtlPath`; `test/control-read.ps1` (P1-lite's
  suite — the template, with the "CLI predates the verb → SKIP, fail under `-Strict`" probe at
  `:35-40`); `test/conformance.ps1` + `test/control-api.json` (43 steps; the runner scrubs
  `AGWINTERM_SESSION_ID`/`PANE_ID`/`PIPE` first — so a bare `session new` in conformance has NO
  caller and must still fall back to active); `tools/check-contract.ps1` compares parsed JSON
  against agwinterm `main`; `tools/fetch-native.ps1:100-105` takes `agwintermctl.exe` from the
  release `native/pinned.json` names (`latest`). CI: `.github/workflows/ci.yml` runs
  `run-all.ps1 -Strict` with `AGWINTERMCTL=bin\agwintermctl.exe`.
- QA: `qa/product.md` (the run recipe — a new case file must be listed), `qa/control-read.md`.
- agwinterm's reference implementations, for wording and edge cases: `src/Agwinterm.Pty/
  ControlServer.cs` (`TryOverlaySize` `:294-307`, the `sidebar` dispatch `:270-282`,
  `HandleSidebarWidth` `:1085-1130`), `SidebarWidths.cs` (`Default=220, Min=120, Max=600`, the
  refusal text), `SessionNewWorkspaces.cs` (the refusal wordings), `src/Agwinterm.Win32/
  Program.ControlHost.cs` (`SessionOverlay` `:655-726` with `NoSessionRefusal`; `NewSession`
  `:252-320`); tests `tests/Agwinterm.Pty.Tests/{OverlaySizeTests,SidebarWidthTests,
  SessionNewWorkspaceTests}.cs`; QA `qa/control-honesty.md`.

## Constraints

- **The contract is agwinterm-first.** `test/control-api.json` must end up what agwinterm's
  `tests/conformance/control-api.json` says after its P2 sibling contract PR: an errors-block step
  `session new --workspace no-such-workspace`, an overlay `open --size-percent` step, a
  `sidebar width` step. Copy it in Task 7 exactly; if the runner cannot express a shape, extend
  `Test-Shape`, not the step. Until agwinterm cuts the release that carries #226, the fetched
  `agwintermctl` has no `--stdin`, no strict `--size-percent`, no `sidebar width` and no `caller`:
  every check that needs them **probes the CLI and SKIPs (fails under `-Strict`)**, the P1-lite
  pattern at `test/control-read.ps1:35-40`. Locally, run with `$env:AGWINTERMCTL` pointing at
  `C:\Users\boris\source\agwinterm\src\Agwinterm.Ctl\bin\Release\net10.0-windows\agwintermctl.exe`.
- **Every refusal leaves the world untouched**, and every refusal is asserted twice: the reply,
  and that nothing changed (the tree, the sidebar, the overlay, the pane's text).
- **Do not widen #21.** `session.new` still creates on the pipe thread; this batch resolves the
  caller's workspace under `LockG` (a read) and passes the index in. It does not move creation to
  the UI thread and does not add locks around what is already unlocked — that is P9-lite, and a
  lock change never ships without its own revmux round (#20 r4/r5).
- **Never hold `g_lock` across a cross-thread `SendMessage`.** A `sidebar width` setter POSTS its
  relayout (`WM_COMMAND` or a new `WM_APP_*`), it does not call `relayout()` from the pipe thread.
- Same reply envelope: `ctlOk` for a value already JSON, `ctlOkStr` for a string, `ctlErr` for a
  refusal. Agwinterm's wordings are quoted in the tasks; use them, the unit suites assert wording.
- `qa/product.md` safety rules in full: sandbox instance (`--pipe <name>`, throwaway
  `%LOCALAPPDATA%`), never `keybd_event` / `SendInput`, `PrintWindow` never `CopyFromScreen`,
  never the real user profile. **HKCU is shared** — a check that writes `SidebarW` restores it.
- Build with `./build.ps1`; the core is not touched (no ABI movement expected).

## Testing Strategy

- **`test/control-honesty.ps1`** (new, registered in `run-all.ps1`): every refusal and every
  positive control in this batch, against a sandbox through the real CLI. Where the CLI predates
  #226, probe and SKIP.
- **`test/control-read.ps1`** keeps what it has; #23 and #24 get their own checks (a minimise +
  pipe-driven resize sequence; a foreground-steal loop with a second window holding focus).
- **Conformance** pins the cross-product contract (Task 7).
- **QA cases** `qa/control-honesty.md` for the parts that need eyes (the divider moved; the popup
  is the size asked for; the window did NOT come to the front).
- Each task's checks must pass before the next task starts.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope

## Implementation Steps

### Task 1: `session.overlay` — the right argument, validated, and honest about failure
- [x] read **`args.size-percent`** (keep `args.size` as a silent alias for one release? No — nothing
      ever sent it except lite's own tests, if any; grep and drop it)
- [x] a strict reader: **absent** → lite's default popup (70 %, unchanged — say in the comment that
      this is lite's default and differs from agwinterm's full-region, and that the contract pins
      shape only); **present and all digits in 1..100** → that fraction of the main window's client
      area; **anything else** → `ctlErr` naming the value and the range and that omitting the flag
      gives the default. `JsonReq::get` cannot tell absent from empty, so use `req.fields.count(…)`
- [x] delete the `min(0.95, …)` clamp in `openOverlay` (`:5050`) — with validation upstream a clamp
      can only hide a bug; 100 means the whole client area
- [x] **resolve the target** (`resolveTarget`) before anything else: a **named** target (non-empty,
      not `active`) that resolves to nothing → `ctlErr("no session matches that target; nothing
      opened, resized or closed")` for open, resize and close alike. lite's overlay is a window-level
      popup, so a target that DOES resolve is accepted whichever session it names; write that down
- [x] `open` with an empty command → `ctlErr("overlay open needs a command; nothing opened")`,
      checked BEFORE the target (agwinterm's order; its fake asserts it)
- [x] add **`resize`**: with an overlay open, re-size the popup to the new fraction on the UI thread
      (post it — a new `WM_APP_OVERLAY` code or a second message; never `SetWindowPos` from the pipe
      thread) and reply `ctlOkStr("resized N%")` with the N asked for; with no overlay →
      `ctlErr("no overlay to resize on that target; open one first")`
- [x] `close` with nothing open → `ctlOkStr("no overlay")` (today `closed`), and an untargeted
      close in an empty window stays `ok` — the conformance step depends on it
- [x] any action other than `open` / `close` / `resize` → `ctlErr` naming the three (today it opens)
- [x] `test/control-honesty.ps1`: `--size-percent 0`, `-5`, `150`, `sixty` each refused and **no
      popup appeared** (`FindWindow` on the popup class, or `tree`'s overlay flag if lite emits one
      — pick the oracle that cannot pass vacuously); `40` opens a popup whose client width is ~40 %
      of the main window's (measure with `GetWindowRect`, ±1 cell); `resize 80` moves it; `resize`
      with nothing open refused; `open` with no command refused and nothing opened; `close
      --target no-such` refused; untargeted `close` with nothing open `ok` "no overlay"
- [x] build + run `test/control-honesty.ps1` — must pass before task 2

### Task 2: `sidebar` stops toggling on words it does not know, and gets `width`
- [x] replace `wantOn` for this verb with an explicit op table: `show`/`on`, `hide`/`off`,
      `toggle`, `state`, `width`; anything else → `ctlErr` naming the ops, **and nothing changes**
      (today it toggles — pin that it no longer does with a before/after `window.state` read)
- [x] `sidebar state` → `ctlOk` JSON `{"visible":bool,"width":N}` (agwinterm's `sidebar state`
      is a string with the width appended; lite has no mode, so an object is the honest shape —
      but check what the contract PR pins for `sidebar width`'s reply and use THAT shape for
      `width`; `state` is not in the contract)
- [x] `sidebar width` (no N) → the width in effect; `sidebar width N` → set. Reply carries `width`
      (in effect) and `visible`; when hidden, the width is stored (it is what `show` will use),
      persisted, and the reply says `applied:false`
- [x] the range: reconcile the three lite numbers — `kSidebarMinW = 90` (`:116`), the registry
      loader's 90..900 (`:2182`), the drag cap of 60 % of the client (`:5451`). Choose `Min = 90`,
      `Max = 900` as the API range (document why: it is what the splitter and the registry already
      allow), refuse outside it naming the range, **and additionally refuse a width that would
      leave the content region narrower than `kMinContentCols * g_cw`** (a new constant, say 20
      columns) against the LIVE client width — this is the #23 trigger a setter would otherwise add.
      Say in the comment that the refusal names which of the two limits was hit
- [x] the set runs on the UI thread: store the width, then POST the relayout (`WM_COMMAND` with a
      new id, or `WM_APP_*`), which repositions the tree (`:5592`) and `syncPaneSizes()` (`:5596`);
      persist through the existing save path (`:2220`). The pipe thread never calls `relayout()`
      (a new `WM_APP_SIDEBARW`, handled by `OnSidebarWidth`: relayout if shown, then `saveColors`)
- [x] `test/control-honesty.ps1`: set 300 → reply 300, `window.state`/`sidebar state` agree, and
      **the content region moved** — the active session's `cols` (via `tree` or `surface cursor`
      geometry, or `emu_info` through `session text` width) shrank by ~120/g_cw; `89` and `901`
      refused and the width did not move; a width that would leave < 20 columns refused (shrink the
      sandbox window first with `window resize` if lite has it, else skip with a note); set while
      hidden → `applied:false`, then `sidebar show` → applied; `sidebar bogus` refused and the
      sidebar did not flip; `on`/`off` behave as `show`/`hide`. **Save and restore HKCU `SidebarW`**
      (➕ `tree` nodes now carry `cols`/`rows` — the oracle for "the content region moved", and the
      one Task 5's #23 check will use; the divider itself is read from the SysTreeView32 child's
      window rect. The narrow-window case shrinks the sandbox with `SetWindowPos` on its own hwnd
      and proves the same 600 is accepted once the window is wide again. `ShowSidebar` is saved and
      restored beside `SidebarW`, since every hide/show writes it)
- [x] build + run `test/control-honesty.ps1` — must pass before task 3 (dev CLI `-Strict`: all
      pass; released 0.17.x CLI: 3 SKIPs, the CLI-side probes; conformance with the dev CLI: green)

### Task 3: a bare `session new` lands in the caller's workspace; the pair is refused
- [ ] read the top-level **`caller`** field (`req.get("caller")` — top level beside `target`, NOT
      `args.caller`; agwinterm sends it there, and `session.new` must stay a targetless verb)
- [ ] resolve it with an **id-or-prefix-only** helper (exact `s->id`, then the ≥4-char prefix rule
      `resolveTarget` uses) — **never the name arm**: `AGWINTERM_SESSION_ID` is an id, and a name
      collision would place a session by accident. Under `LockG`, read `s->ws`
- [ ] precedence, written in one comment: explicit `--workspace` / `--workspace-name` (unchanged);
      else the caller's `ws`; else `g_activeWs` — **the LAST answer**, with the sentence from the
      agwinterm plan about why ("active" is a global the UI rewrites on every click, every
      selection and every `workspace.new` over the API). A caller that does not resolve (closed
      pane, unrelated shell, the conformance runner which scrubs the env) is NOT refused
- [ ] pass the index into the creation (`wantWs`), so `newSession()`'s `g_activeWs` read at `:1825`
      is overridden the same way an explicit workspace already is (`:6408`). Do not touch the
      pipe-thread creation itself (#21)
- [ ] **`--workspace` with `--workspace-name` → `ctlErr`** before anything is created, agwinterm's
      wording: "pass --workspace or --workspace-name, not both"
- [ ] `test/control-honesty.ps1`: from a pane in workspace B with A active (make B via
      `workspace new`, put a session in it, then `workspace select` A), run a bare `session new`
      with `AGWINTERM_SESSION_ID` set to B's session — **through the CLI, so it must be a
      post-#226 client** (probe and SKIP otherwise) — and assert in `tree` that it landed in B;
      select a session in A (`session select`) and run a second bare create from the same caller
      → B again (the regression test); `--workspace 0` beats a caller in B; a stale caller id
      falls back to active and CREATES; no caller (env scrubbed) → active, unchanged; the pair
      refused and no session created
- [ ] build + run `test/control-honesty.ps1` — must pass before task 4

### Task 4: `--stdin` — prove the shared client against lite's decoder, and say so
- [ ] `test/control-honesty.ps1`: pipe a here-string with a quote, a newline, two consecutive
      spaces and a leading `--` into `session type --stdin` through the CLI (probe for `--stdin`;
      SKIP when the client predates it), then read it back with `session text` **byte for byte**;
      send the same text as positional argv and show what is lost. A lone `0x80` from a file:
      non-zero exit and the pane received nothing — that is CLI-side, but it is the only lite-side
      proof that nothing reaches the pane
- [ ] docs: `kSkillMarkdown` `session type` prose (`:6156-6158`) and `README.md` — `--stdin` is how
      text with quotes or newlines is sent; lite's server behaviour is unchanged. `quick type` is
      spelled `session type --target <quick session id>` here too
- [ ] build + run — must pass before task 5

### Task 5: #23 — a pane never collapses to 2 columns
- [ ] `paneGridSize` (`:1374`): a non-viable rect — the window minimised (`IsIconic(g_hwnd)`), or
      `contentW <= 0`, or fewer than one cell — **does not answer**: return `false` (or leave the
      out-params untouched and return a flag) and make every caller skip the resize instead of
      pushing 2×2. `OnSize` already guards `SIZE_MINIMIZED`; `session.new` / `session.split` /
      `syncPaneSizes` on a pipe thread do not — they now inherit the guard
- [ ] `hostResize` (`:1394`): the compare-and-set, the host request and `emu_resize` under one
      hold, and **check `request()`'s return** — on failure roll `s->cols` / `s->rows` back so the
      next `syncPaneSizes` retries. The hold spans a pipe round trip to the pty-host, not a
      cross-thread `SendMessage`; say so in the comment and say why that is allowed (the UI thread
      never waits on a pipe thread for this)
- [ ] re-clamp `g_sidebarW` in `OnSize` against the current client width with the same
      `kMinContentCols` rule Task 2 introduced, and validate the two persisted values against each
      other at load (`:2182` vs the startup rect `:7415`)
- [ ] `test/control-honesty.ps1` (or `control-read.ps1`): minimise the sandbox
      (`ShowWindow(SW_MINIMIZE)` on the sandbox's own hwnd — its own handle, not global input),
      drive `session select` / `session split` / `session new` over the pipe, restore, and assert
      every visible session's cols from `tree`/`emu` matches its pane rect; a sidebar saved at 900
      and a window opened at 700 px wide starts with a clamped sidebar and a ≥20-column pane
- [ ] build + run — must pass before task 6

### Task 6: #24 — the window stops coming to the front on its own
- [ ] a helper `raiseIfAllowed(HWND)`: `SetForegroundWindow` only when
      `GetForegroundWindow()` belongs to this process (or `GetWindowThreadProcessId` matches);
      otherwise `FlashWindow(TRUE)` — the `HA_BELL` pattern (`:5649`). Use it at `:5034`, `:5044`,
      `:5059`
- [ ] delete the raises in the popup's `WM_CLOSE` (`:4987`) and `WM_DESTROY` (`:4998`) — Windows
      restores activation to the owner on its own
- [ ] `window.select` (`:6857`): keep the raise (it is the verb's purpose) but reply whether it was
      **granted** — `GetForegroundWindow() == hwnd` afterwards — instead of always `selected`; the
      same defect class as the rest of this batch
- [ ] delete the dead duplicate `window.zoom` / `window.move` / `window.resize` / `window.state`
      arms at `:6944-6963`
- [ ] `test/control-honesty.ps1`: start a sandbox, give the foreground to a SECOND sandbox (its own
      hwnd, `SetForegroundWindow` from the test is a user-process gesture — acceptable, or use
      `window select` on it), then call `quick on` / `quick off` twenty times and `session overlay
      open`/`close` five times on the FIRST; assert `GetForegroundWindow()` never became the first
      sandbox's hwnd; assert `window select` on a window that cannot be raised reports it
- [ ] build + run — must pass before task 7

### Task 7: the contract, the skill, the docs
- [ ] copy agwinterm `main`'s `tests/conformance/control-api.json` (post-#226 sibling contract PR)
      to `test/control-api.json`; `tools/check-contract.ps1` must pass. Extend `Test-Shape` only if
      a new step needs a kind it lacks
- [ ] `test/conformance.ps1` runs green against a sandbox with the released CLI where it can, and
      with `$env:AGWINTERMCTL` at the agwinterm dev build for the new steps
- [ ] `kSkillMarkdown`: the overlay refusals and `--size-percent` range; `sidebar width` and the
      unknown-op refusal; the caller-workspace rule and the pair refusal; `--stdin`; `window.select`'s
      honest reply. Keep `session restore` in the "does NOT have" list
- [ ] `README.md`: the verb count at `:65-68` if it changed, and the agwintermctl section
- [ ] agwinterm `docs/lite-parity.md`: mark the P2-lite section done with this PR number, and
      **correct `:113-114`** — `sidebar.width` is mirrored here, not deferred to P10; `session.restore`
      stays P9. (A one-line agwinterm PR, or folded into its next docs change.)
- [ ] `qa/control-honesty.md` (listed in `qa/product.md`): the popup is the size asked for; the
      divider moved; the window did NOT come to the front while an agent loop ran
- [ ] build + run `test/run-all.ps1 -Strict` locally with the dev CLI — must pass before task 8

### Task 8: [Final] Verify acceptance criteria
- [ ] verify every Overview item against the CODE, not the plan
- [ ] verify the edge cases: `--size-percent 100`; `resize` on a popup the user closed by hand a
      moment ago; `sidebar width` while a splitter drag is in progress; a caller that is the
      quick/scratch/overlay session; `session new --workspace 0 --workspace-name x`; a 900-px
      sidebar restored into a 600-px window; `quick on` while the user is typing in another app
- [ ] `tools/check-contract.ps1` green; `test/run-all.ps1 -Strict` green with the dev CLI; note
      which checks SKIP with the released CLI and why (the release gate)
- [ ] the 80-session stress from P1-lite r5 (`r5-stress.ps1` shape: two creators + a deleter + a
      streaming pane) still runs to completion — #23's `hostResize` hold is a lock change, and a
      lock change gets stressed before it gets reviewed
- [ ] close #23 and #24 with the PR, quoting the check that pins each
- [ ] mark P2-lite in agwinterm's batches index and `docs/lite-parity.md`

## Technical Details

- **Why lite keeps its 70 % default.** agwinterm's overlay is a cover drawn inside the session's
  content region, so "absent = full region" is natural there. lite's is a separate popup window;
  "full" would hide the main window entirely. The contract pins the reply shape and the refusal,
  not the default geometry, and the skill says which default each product has.
- **Why `open` keeps answering a string, not the overlay id.** lite creates the overlay on the UI
  thread from a posted message; the session id does not exist when the reply is written. Answering
  an id would mean either a synchronous hop (a cross-thread `SendMessage` from a pipe thread under
  no lock — possible, but a new pattern for this file) or a made-up id. Neither belongs in a batch
  about not lying. Written down as a known gap; P9-lite can revisit when `session.split` returns
  ids the same way.
- **Why the caller resolves by id only.** The value is the pane's own `AGWINTERM_SESSION_ID`; a
  session NAME equal to some other session's id prefix is unlikely but not impossible, and the cost
  of the collision is a session in the wrong workspace — the exact bug this task removes.
- **Why `hostResize` may hold across the pty-host round trip.** The rule from #20 is about a
  cross-thread `SendMessage` while holding `g_lock`, because the UI thread may be waiting for the
  same lock and the sent message needs the UI thread to pump. The pty-host request is a pipe write
  and read on `g_reqLock`; the UI thread never blocks on a pipe thread to complete it. The stress
  in Task 8 is the check that this reasoning holds.

## Post-Completion

*Informational — no checkboxes*

- **Release gate.** The suite's `--stdin`, `--size-percent`, `sidebar width` and `caller` checks
  SKIP with the released `agwintermctl` until agwinterm tags the release that carries #226 (Boris
  calls the tag); `check-contract` is red between the agwinterm contract PR merging and this PR
  merging — expected, the same rule P1-lite followed.
- lite's own release (the installer is still 0.17.14 with `main` above it) — Boris calls it.
- #21 (pipe-thread mutation without `g_lock`) is P9-lite; this batch adds a read under `LockG` and
  nothing else to that surface.
- Review: **revmux**, two rounds minimum, and a narrow round for each fix commit. Every P2 round
  so far — agwinterm r1, r2, r3 — found something in the previous fix; plan for four.
