# P5-lite — a pane gets its own overlay, the agliteterm half

The agliteterm half of batch **P5** of the parity programme (agwinterm
`docs/plans/2026-09-03-parity-batches.md`). agwinterm shipped its half as PR #250 on 2026-09-07
(plan: agwinterm `docs/plans/completed/2026-09-07-p5-pane-overlays.md`, three revmux rounds —
read it first, the rule and the refusal table above all; every rule below was made there and lite
copies it, it does not re-decide it), followed by the contract PR #252 (four steps, three refusals)
and the release PR #253 (0.17.14). `tools/check-contract.ps1` goes red on `main` the moment #252
merges, for exactly those steps and refusals; that is the gate, and it goes green when this merges
and agwinterm 0.17.14 is tagged.

**Gates, decided before ralphex runs — all five as recommended, Boris, 2026-09-07 ("Ok
continue" to the five questions as listed below); the plan as written is the decision:**

1. **A pane overlay is IN-WINDOW, the pane's surface** — one more hidden `Session`, drawn in the
   pane's box instead of the shell while it is open. Not a popup sized to the pane rect (a popup
   is a framed top-level window that does not follow the main window, is raised only when the
   process holds the foreground, and `g_focusOverride` sends EVERY keystroke to it — the sibling
   pane could not stay interactive, which is the rule's one hard property), and not a recorded
   divergence (the contract runs the same steps on both products). The session-wide overlay stays
   the popup it is, byte for byte.
2. **`session text` keeps lite's default (the whole buffer) and gains `--lines N` and `--all`.**
   `--all` is the explicit spelling of what the bare form already does here; `--lines N` (silently
   dropped today) is the last N lines; the two together are refused. `overlay text` is the same
   reader with the same defaults. A recorded divergence: agwinterm's and agterm's bare `session
   text` is the screen only. The alternative — switch the default to the screen — changes a shipped
   verb the skill documents as "the whole buffer" under every caller's feet.
3. **`overlay result` reports the command's exit status through an FTCS mark** the overlay's own
   command line emits around the command (`OSC 133;A` / `C` before it, `D;<code>` after it; the
   core already parses these — `lastCommandOutput` reads them). The shell stays up (`-NoExit`, the
   P2-lite shape; lite has no `--wait`), so `result` says `overlay still running` while the slot is
   open and `exit N` after it closed, `no overlay result` when nothing completed there. One command
   line for the popup and the pane slot, so the bare `result` (window-wide, agwinterm's recorded
   divergence from agterm) works too. The alternative — no exit code, `result` limited to
   running / never ran — makes the verb answer nothing a caller wants it for.
4. **`open --pane` answers the overlay's id** (a lite session id, `<prefix>-<seq>`), because the
   pane slot is created inline the way `session split on` is; the popup keeps its status word (it is
   created after the reply is written). The contract note in #252 that says "lite: its status word"
   is corrected there before it merges.
5. Release after this: lite **0.17.16** (Boris calls the number).

One verb family and one rule, on one subsystem — a session's two panes and the popups over the
window. In lite a pane IS a `Session` (P4: the owner's shell or the split's hidden shell), so a pane
overlay is one more hidden `Session` hung on the shell it covers (`Session::overlay`), sized to the
shell's grid, painted in its box, and reached by `focusedSession()` / `hitTest` when that pane is
the one under the keys or the pointer. Nothing in the popup machinery changes; the popup is the
session-wide slot.

## The vocabulary, fixed before anything is written

Copied, not re-decided, from the agwinterm plan:

- **THE RULE, stated once in lite's terms** (agwinterm `ISessionHost.SessionOverlay`'s sentence;
  quoted here in full and nowhere else in full — the skill, the README and the code comment point
  here): a session has three overlay slots: **one session-wide** (lite's popup over the window,
  as today — it covers every pane and any pane overlay under it, and holds input through
  `g_focusOverride` while focused) and **one per pane**. A pane overlay covers **exactly one
  pane's box** — always the full box, never floating — and the sibling pane stays visible and
  interactive. `--pane left|right` names the slot: `left` is **slot 0** (the left / top box) and
  `right` is **slot 1** (the right / bottom box) **whatever the axis** — the same slots `session
  focus left|right` names, whichever shell a swap put there; a non-split session accepts `--pane
  left`; the flag omitted means the session-wide slot — today's behaviour, byte for byte. A pane
  overlay is that pane's **surface** while it is open: keys typed into the focused pane, the mouse
  inside the pane's box and `--target active` reach the overlay; `--target <pane id>` reaches the
  shell **underneath** (`session text` reads the surface underneath); `--target <overlay id>`
  reaches the overlay from anywhere (every `session` verb — lite resolves hidden sessions by id
  already), and on `session overlay` itself names that overlay's slot — the same as passing its
  `--pane` word — for as long as the id resolves (an overlay that closed is reached by `--pane`
  only); with `--pane` naming the other side it is refused. The slot moves with its pane (a swap,
  a `split close` of the other pane — in lite by construction: the slot hangs on the shell) and
  dies with it (`split close`, `split off`, the shell exiting when that removes the pane — a
  single-pane session keeps an exited shell on screen, and its overlay with it — `session close`,
  the window closing).
- **A slot is a position, a shell is a `Session`** (P4). The pane overlay of slot X lives on
  `g_sessions[g_pane[paneOfSlot(X)]]->overlay` for the displayed session; on a non-displayed
  session `paneOfSlot` is computed from the owner's `swapped` the way `splitBlockFields` does.
- **An overlay id is a session id.** The pane overlay's `Session` is minted by `newSession` and
  attached hidden, named `overlay`, never in `g_pane`, never a tree node, never in the state file,
  never adoptable (`restore capture` already refuses covers). Its id is the `open` reply and the
  `AGWINTERM_SESSION_ID` / `AGWINTERM_PANE_ID` of the program inside it — so a bare `session
  overlay close` typed inside a pane overlay closes that overlay (the CLI sends the env id as the
  target), and a bare `session text` inside it reads it.
- **`--wait` / `--block` stay out** (not in the contract; lite's overlay stays up until closed,
  which is `--wait` without a banner — recorded in P2-lite). **`--size-percent` / `resize` with
  `--pane` are refused** at both ends (the CLI, exit 2 "Nothing sent"; the server for a raw client)
  with agwinterm's sentences — a pane overlay is always full-box.
- **Lite's differences from agwinterm's sentence, each recorded in `lite-parity.md`, not
  silently**: (a) the session-wide slot is a popup, not a cover inside the content region (P2-lite,
  unchanged); (b) `session text` / `overlay text` default to the whole buffer (gate 2); (c) `exit N`
  is the exit status of the command `open` ran, as PowerShell reports it — `$LASTEXITCODE` for a
  native program, else 0 when `$?` is true and 1 when it is false — read off the FIRST mark with an
  exit in that overlay (the wrapper's; a user's own shell integration prompts come later); a command
  that never completed (closed early, or a command line that did not parse) leaves the slot's
  result as it was; (d) the session-wide `open` keeps accepting any target that resolves (P2-lite),
  where agwinterm refuses a pane id of a split without `--pane` (#213); (e) `open --pane` answers
  an id, the popup a status word (gate 4).

Refusals are agwinterm's sentences **verbatim** (`src/Agwinterm.Pty/OverlayPanes.cs` — agterm's
phrase as the head, a colon, what our guard saw); grouped in one `// ---- P5: the overlay verbs'
refusals ----` block beside P4's (`src/main.cpp:7012-7053`), the overlay's five inline literals
(`:8093`, `:8110-8111`, `:8123`, `:8132`, `:8143`) promoted into it unchanged:

| agterm phrase | when | ours, after the colon |
| --- | --- | --- |
| (parse) | `--pane` is not exactly `left` / `right` | `OverlayPanes.Refusal`: both words named, the absent form named; nothing opened |
| `pane not visible` | `--pane right` on a single-pane session | `session <id> has one pane; pass --pane left or omit --pane` |
| `pane overlay already open` | `open --pane X` while X holds one — **no silent replace** (the popup replaces, as today) | `close it first (session overlay close --pane X), or read it (result / copy / text)` |
| `no overlay` | `copy` / `text` / `result`? no — `copy` / `text` / `close --pane` with nothing in the slot (`close` answers it `ok`, the popup's shape) | `--pane X` names which slot |
| `no selection` | `copy` with nothing selected inside the overlay | — |
| `failed to read surface buffer` | `text` when the emulator read fails | the reason |
| `overlay still running` | `result --pane X` (or `--target <X's overlay id>`) while X's overlay is up | — |
| `no overlay result` | `result --pane X` when nothing completed in X since the window opened | — |
| (agreement) | `--target <pane id>` naming the OTHER side than `--pane` | `OverlayPanes.Disagree`: `'<id>' is the right pane; --pane left names the other one. Nothing opened.` (overlay flavour for an overlay id) |
| (in flight) | an overlay id that resolved on the pipe thread and is gone in the UI hop | `OverlayIdGoneRefusal` — lite runs the slot's verbs inline under `g_lock`, so this is documented as agwinterm's, not emitted, unless a path produces it |
| (usage) | `--pane` + `--size-percent`; `resize --pane`; `--all` + `--lines` | `SizeWithPane`, `ResizeWithPane`, `AllWithLines` — the CLI refuses first; the server repeats the sentence for a raw client |
| (cover) | `session close --target <any overlay's id>` | the P4 cover family: `session close: '<id>' is a scratch/overlay/quick pane, not a session; \`session scratch off\`, \`session overlay close\` or \`quick off\` dismiss those. Nothing closed.` — closes a latent hole: today `:8079-8080` destroys the popup's `Session` under `g_overlaySession` |

`overlay not realized` is agterm's phrase for a slot whose terminal is not up yet; `newSession`
builds the emulator before it returns, so it is documented, not emitted (agwinterm's decision).

## Overview

- **`session overlay open <cmd> --pane left|right [--target <id>]`** — the command runs in a hidden
  `Session` sized to that pane's grid, drawn in that pane's box instead of its shell; the other
  pane keeps rendering and taking input. Created inline on the pipe thread the way `session split
  on` creates the split shell (`:8398-8506`), so the reply is the overlay's id. Refused, nothing
  opened: a bad word; `pane not visible`; `pane overlay already open`; the agreement check; a
  target that resolves to nothing (`:8130-8132`'s sentence); a cover as the target without `--pane`
  stays the popup's arm. Without `--pane`: unchanged — the popup (`openOverlay:5899`), `WM_APP_OVERLAY`,
  the status word, the 70 % default, the floor and its wording.
- **`session overlay close --pane left|right`** — kills that slot's session (the way
  `closeSplitSide` kills a shell: listed out under `g_lock` first, then the host kill) and the pane
  shows its shell again; `ok "no overlay"` when empty. **`session overlay result [--pane
  left|right]`** — new action: with a pane, that slot's `overlay still running` / `exit N` / `no
  overlay result`; bare, the window-wide last popup exit (`exit N`, or `ok "no overlay"` when none;
  reset to `no overlay` by any popup open — agwinterm's `_lastOverlayExit`).
- **`session overlay copy [--pane left|right]`** — `{"text": <the selection inside the overlay>}`
  (`g_sel.isFor(overlay)` → `selectionText()`; the clipboard is not touched); `no overlay` / `no
  selection`. Without `--pane` on the popup: the popup paints no selection and `hitTest` never
  enters it, so `no selection` is what a caller gets — said in the skill, not hidden. **`session
  overlay text [--all] [--lines N] [--pane left|right]`** — `{"text": …}` through
  `dumpBufferRange` on the overlay's session; `--lines N` = the last N lines of the buffer; `--all`
  and the bare form the whole buffer (gate 2). **`session text` gains `--lines N` and `--all`** —
  the same reader, the same words, `--all` + `--lines` refused.
- **`tree --json`**: `"paneOverlays":["left"]` / `["right"]` / `["left","right"]` inside the
  session node in slot order, **omitted when empty**, beside the split block — agwinterm's key, an
  ARRAY of words (not an object keyed by pane id; `capturedCommands` is the object).
- **The surface seam**: `focusedSession()` (`:1624`), `paint`'s pane loop (`:3920-3930`),
  `hitTest` (`:4028`), `paneGridSize` / `syncPaneSizes` (`:1558`, `:1790`), `InvalidateCaret`
  (`:6405`), the wheel (`:6277`) — each asks `surfaceOf(shell)` (= `shell->overlay ? overlay :
  shell`) where it used the shell. Selection works inside a pane overlay by construction (`g_sel`
  is keyed by `Session*`). A badge `overlay` in the box's top-right corner tells a human the box is
  covered (the popup's title word).
- **Keys**: the Close Pane / Session action (`IDM_CLOSE` → `closeFocused:2414`, the unbound
  `Key_Close`, the palette row, the File menu) closes the focused pane's overlay FIRST when one is
  open (agwinterm's ⌘W rule), else what it closes today. Lite's Esc is the palette (`:4606`) — no
  `close_cover` chord exists here; nothing added.
- **Lifecycle**: `closeSessionAt` (a session close kills both panes' overlays), `closeSplitSide`
  (the victim's overlay dies, the survivor keeps its own — the pointer exchange moves the whole
  object, so a promotion keeps the survivor's slot), the `WM_APP_PANEEXIT` collapse (the same
  primitive), `OnDestroy` (everything in `g_sessions`, already). A swap moves nothing (the slot is
  on the shell). `selectPrimary` needs nothing (a non-displayed session's pane overlay is simply
  not painted). Restore: never persisted (`hidden` is skipped by the writer).

## Context (from discovery)

- Overlay state `src/main.cpp:481-485` (`g_overlayHwnd` / `g_overlaySession` / `g_focusOverride`,
  one popup per process); `openOverlay` `:5897-5915` (`DestroyWindow` the old one at `:5900`,
  `powershell.exe -NoExit -Command <cmd>` at `:5905`, `hidden` + name `overlay` `:5912`,
  `showPopupRaised` → `g_focusOverride` `:5913`); `resizeOverlay` `:5920-5936`; the popup class
  `:5725-5764` (one class for quick / scratch / overlay, told apart by HWND); `popupProc`
  `:5656-5724` (`WM_SETFOCUS` / `WM_KILLFOCUS` set / clear the override `:5666-5667`, `WM_CLOSE`
  destroys overlay and scratch `:5699-5708`, `WM_DESTROY` kills the session and nulls both globals
  `:5709-5721`); `paintPopup` `:5643-5655` (pane `-1`: no selection drawn); `windowForSession`
  `:1630-1635`; `refitPopupSessions` `:1817-1828`; `applyTheme` `:907`.
- The verb `session.overlay` `:8083-8164`: action `open|close|resize` `:8090-8093`;
  `size-percent` by presence `:8102-8113`; the command before the target `:8121-8123`; the target
  `:8130-8132`; dispatch `:8136-8163` (`close` with none → `ctlOkStr("no overlay")` `:8138`;
  `OverlayReq` posted as `WM_APP_OVERLAY` `:1021`, handler `:6527-6532`). No `wait` / `block` /
  `pane` / `all` / `lines` anywhere (`grep 'args\.'`).
- Splits (P4): `struct Session` `:355-429` (`splitId` `:361`, `paneId` `:368`, `horizontal`
  `:375`, `swapped` `:381`, `hidden` `:385`); the slot map `:1519-1550` (`slotOf`, `paneOfSlot`,
  `slotRect`, `paneRect` — the one geometry choke point); `displayedLayout` `:1513`;
  `splitOwnerOf` `:7086-7090` (a cover answers `nullptr`); `splitBlockFields` `:7097-7103`;
  `closeSplitSide` `:2446-2500` (the pointer exchange, `g_sel.pane` reset `:2485`);
  `closeSessionAt` `:2325-2375`; `closeFocused` `:2414-2418`; `unsplit` `:2518`;
  `OnPaneExit` `:6551-6563`; `session.split` `:8398`, `.split.close` `:8507`, `.swap` `:8542`,
  `.focus` `:8585`, `focusSlotFor` `:7059`.
- Surfaces: `focusedSession` `:1624-1628`; `paint` `:3915-3936` (`paintPane(mem, pr, session, p,
  p == g_focus)`); `paintPane` `:3728` (the selection test `:3839` is `g_sel.isFor(s) && g_sel.pane
  == pane`); `hitTest` `:4028-4049`; `struct Sel` `:1087-1110` (keyed by `Session*`, `isFor`
  `:1105`); `selectionText` `:4078-4124`; `syncSelection` `:4058`; `paneGridSize` `:1558`;
  `syncPaneSizes` `:1790-1811` (`hostResize` per pane); `InvalidateCaret` `:6405`; `OnMouseWheel`
  `:6277`; `handleKeyDown` `:4595` (Esc = palette `:4606`); the exit path `:1976-1981`
  (`exited = true`, `WM_APP_PANEEXIT`).
- Reads: `dumpBufferRange` `:7213-7249` (history + screen as one absolute sequence, `-1,-1` =
  everything), `dumpBufferText` `:7250`; `session.text` `:8011-8014` (ignores `lines`);
  `session.output` `:8004` / `lastCommandOutput` `:7258-7279` (FTCS marks, `FfiMark` `:88-92`:
  `hasExit`, `exitCode`); `session.copy` `:8634-8638` (`ctlOkStr("")` when the selection is not
  the target's — pre-existing, untouched). The core's `ftcs_dispatch` (agwinterm
  `native/agwinterm-core/src/emulator.rs:873-922`): `A` opens a mark, `D;<n>` closes it with
  `exit_code` — the wrapper emits `A`, `C`, the command, `D;<code>`.
- Resolution: `resolveTarget` `:7147-7173` (empty / `active` → `focusedSession()`; exact `id`;
  exact `paneId`; ≥4-char prefix of either — hidden sessions included; names among visible only
  `:7165`); `callerWorkspace` (P4 r2: a hidden caller walks to its owner — a pane overlay's caller
  needs the same walk to the shell that holds it, then that shell's owner).
- Refusal blocks: P3 `:6980-7010`, P4 `:7012-7053` — the overlay's are inline literals today.
- Tree `:7715-7805`: hidden skipped `:7727`; `capturedCommands` `:7765-7775`; the split block
  `:7783` / `paneIds`-alone `:7796`; `active` `:7739`. `window.state` `:8965` has
  `quickTerminalVisible`, no `overlayVisible` (unchanged).
- `session.close` `:8057-8082`: a hidden target that is no split shell falls to `closeSessionAt`
  `:8079-8080` — the dangling `g_overlaySession` (pre-existing; fixed here because a pane overlay
  is one more cover it could reach). `session.context` `:8265` and `restore.capture` `:7008` refuse
  covers already.
- Skill `kSkillMarkdown` `:7289-7690`: the overlay section `:7485-7513` ("A command in a popup
  over the window"), `session text` = "the whole buffer" `:7583`, the verb index `:7636`;
  `README.md:51`, `:69` (48 verbs), `:86` (the P2 overlay paragraph), `:102`, `:200`;
  `qa/panes.md`, `qa/control-honesty.md`, `qa/selection.md`, `qa/product.md` (sandbox rules).
- Tests: `test/control-api.json` (mirrored, refreshed ONLY by `tools/check-contract.ps1 -Update
  [-Url <raw url>]` — the `-Url` arm takes #252's branch file until #252 is on `main`, then `main`
  again); `test/conformance.ps1` (probes `:55-104`: `$cliHasP4` = `session swap x` → "Nothing sent"
  `:79`; `Needs-NewClient` `:90-103`; the `checked + skipped == steps` guard); `test/control-honesty.ps1`
  (probes `:38-67`; the overlay block `:235-470` finds the popup by title `agliteterm — overlay`
  `:157` and its session id through `events` `:259`; `# ---- P4: splits ----` `:1547`, its
  `$cliHasP4` gate `:1557`); `test/clipboard.ps1:65-68` (a mouse drag by `PostMessage`
  `WM_LBUTTONDOWN` / `WM_MOUSEMOVE` / `WM_LBUTTONUP` into the app's own window — the selection
  recipe to reuse inside a pane overlay); `test/ui-lib.ps1` (`Start-Sandbox` / `Send-Ctl` /
  `Get-PaneText`; the HKCU rule `:1-16`); `test/run-all.ps1` (twelve suites, `-Strict` through).
- Versions: `installer/agliteterm.iss:6` `AppVersion "0.17.15"` is the single source; `ping`
  answers it. CI: `check-contract` between build and suites; the suites run `-Strict` with
  `AGWINTERMCTL=<workspace>\bin\agwintermctl.exe` — the RELEASED CLI, so every P5 check SKIPs (=
  fails under `-Strict`) until agwinterm tags 0.17.14 (#253 merged, then the tag — Boris). Red by
  design until then, as P4-lite before 0.17.13.

## Constraints

- **Do not hand-edit `test/control-api.json`.** `tools/check-contract.ps1 -Update` (with `-Url`
  pointing at #252's branch while it is unmerged) once; re-run from `main` after #252 merges — the
  parsed content is the same.
- **The popup is unchanged in every observable way**: the same replies (`overlay opened at N%`,
  `resized N%`, the floor wording, `closed`, `no overlay`), the same `WM_APP_OVERLAY` hop, the same
  70 % default, the same accept-any-resolving-target rule, the same title. The honesty suite's
  overlay block (`:235-470`) passes unchanged. The one addition it takes is the wrapped command
  line (gate 3), which changes nothing the block reads.
- **A pane overlay is always full-box.** `--pane` + `--size-percent`, `resize --pane`: refused at
  the CLI (already, #250) AND the server (a raw client), agwinterm's sentences.
- **`left` = slot 0, `right` = slot 1, whatever the axis** — the rule's sentence, once.
- **Refusals leave the world untouched**; a target is resolved once, and every write re-checks
  `indexOfSession` under `g_lock` (#21). A verb on a non-displayed session must not move focus or
  selection (#230). The slot's verbs run INLINE on the pipe thread the way `session split on` and
  `closeSplitSide` do — everything structural under one hold of `g_lock`, the host round trip
  outside it — never post-and-return (the reply is read off state that exists).
- **Every path that finds, sizes, paints, kills or counts a shell handles its overlay**: the
  Context list is the checklist (`closeSessionAt`, `closeSplitSide`, `OnPaneExit`, `syncPaneSizes`,
  `paint`, `hitTest`, `focusedSession`, `InvalidateCaret`, the wheel, `callerWorkspace`, the
  tree, the state writer's `hidden` skip, `restore.capture`'s cover refusal, `session.close`'s new
  one). A missed one is a leak, a dangling pointer or a crash, not a Minor.
- **Refusal sentences are agwinterm's, verbatim** (`OverlayPanes.cs`) — one spelling, one block.
- **No ABI change, no pty-host protocol change** (`tools/check-abi.ps1`); the exit code travels
  inside the terminal stream as an FTCS mark, which the core already parses.
- **HKCU\Software\agliteterm is shared with the user's real app** — any test that writes it
  (`Key_Close` for the chord check) restores it. Sandbox rules of `qa/product.md` in full:
  `--pipe`, throwaway profile, `--no-restore` never against real data, `PrintWindow` never
  `CopyFromScreen`, never `keybd_event` / `SendInput` — `PostMessage` to the app's own handles.
- **The rule is quoted, not paraphrased**: the vocabulary section above is the one full copy; the
  skill's overlay section quotes it; the code comment beside `Session::overlay` points at the plan
  path. A sweep for the OLD wording ("one popup per window", "a popup over the window", "whichever
  session it names", "the whole buffer") across `src/`, `README.md`, `qa/`, `docs/` is part of the
  docs task (P4 r3's lesson).

## Testing Strategy

- **Conformance** — `check-contract -Update -Url <#252's raw file>`, then `test/conformance.ps1
  -Strict` passes every step and refusal against a P5 `agwintermctl` (the dev build at agwinterm
  `src/Agwinterm.Ctl/bin/Release/net10.0-windows/agwintermctl.exe`, `AGWINTERMCTL`). A fourth
  client probe `$cliHasP5` (`session overlay resize --pane left --pipe conform-probe` → a post-#250
  client refuses with "Nothing sent" before any pipe; an older client drops `--pane` and fails to
  connect) and a fourth `Needs-NewClient` rule: `session overlay` with `--pane`, `overlay copy` /
  `overlay text`, `session text --all` / `--lines` → `this agwintermctl predates agwinterm #250 and
  drops --pane / --all and refuses overlay copy / text on its own side - set AGWINTERMCTL to a newer
  build`. The `checked + skipped == steps` guard still holds.
- **Honesty** — a `# ---- P5: pane overlays ----` block in `test/control-honesty.ps1`, guarded by
  `$cliHasP5`, in a sandbox split vertical: `open "cmd /c ping -n 60 127.0.0.1" --pane right` → an
  id that `session text --target <id>` reads (the ping output) and `tree` shows as `paneOverlays ==
  ["right"]`; the left pane is interactive (`session type --target <left pane id>` lands a marker
  `session text --target <left pane id>` reads back) and the RIGHT pane's shell is still there
  underneath (`session text --target <right pane id>` is the shell, not the ping); `overlay text
  --pane right` = the same buffer as `session text --target <id>`, `--lines 2` its last two lines,
  `--all` the same as bare; `--target active` after `session focus right` reads the overlay;
  `overlay copy --pane right` → `no selection`, then a `PostMessage` drag inside the right box
  (`clipboard.ps1`'s recipe) → `copy` returns text and the clipboard is unchanged; `open --pane
  right` again → `pane overlay already open`, the tree unchanged; `open --pane left` →
  `["left","right"]`; `swap` → the words stay `["left","right"]` and `overlay text --pane left` is
  now the ping (the slot moved with its shell); with one overlay: `["right"]` → swap → `["left"]`;
  `result --pane left` → `overlay still running`; `close --pane left` → `closed`, the tree entry
  gone, the pane's shell drawn again (`session text --target active` is the shell), the overlay's
  id resolves nowhere, no orphaned host process; `result` after a quick command: `open "cmd /c exit
  3" --pane left`, settle, `result --pane left` → `overlay still running`, `close`, `result` →
  `exit 3`; `Get-Item C:\no-such` → `exit 1`; `'ok'` → `exit 0`; `result --pane right` (never ran)
  → `no overlay result`; `--target <overlay id>` on `result` / `text` / `close` names the slot, and
  with `--pane <other side>` is refused with nothing done; `open --pane left --target <right pane
  id>` → the agreement refusal, nothing opened; `open --pane right` on a single-pane session → `pane
  not visible`; `open --pane top` → both words named; `close --pane right` when empty → `ok "no
  overlay"`; `--size-percent` beside `--pane` and `resize --pane` refused server-side through a raw
  request (`Send-Ctl`); `split close --target <the pane with the overlay>` → `paneOverlays` gone, the
  id resolves nowhere, the host process count unchanged; `split off` with the split shell holding
  one; the shell UNDER an overlay exiting (`session type "exit\n" --target <pane id>`) → the collapse
  takes the overlay; `session close --target <overlay id>` refused with the cover sentence and the
  overlay still there; the popup opened over two pane overlays → `overlay` and `paneOverlays` both in
  the node, the popup closed → both still running; the bare `result` → `exit N` of the last popup's
  command after its close, `no overlay` (ok) before any; the Close Pane / Session chord (`Key_Close`
  seeded to Ctrl+Shift+W in HKCU before the sandbox launches, restored after) with the focused
  pane's overlay up closes the overlay and keeps the pane; a pane overlay on a NON-displayed session
  by name (#230: focus and selection unchanged, `paneOverlays` on its node); `session text --all` =
  `session text`, `--lines 3` = 3 lines; every open / close emits `tree`.
- **Restore matrix** — nothing new to persist; one `Cell`: a session with a pane overlay saved,
  killed and relaunched comes back WITHOUT it (`paneOverlays` absent, the file unchanged in shape).
- **QA** — `qa/panes.md` gains a case: a pane overlay in the right pane with the left pane typed
  into (`PrintWindow` capture: the left box shows the typed text, the right box the program, the
  divider intact, the badge at the right box's top-right); the `.png` beside the plan as P4 did.
- Each task's checks pass before the next task starts; `test/run-all.ps1 -Strict` green with the
  dev CLI before the PR.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope

## Implementation Steps

### Task 1: the vocabulary, the refusal block, the command line, `result` and the cover refusal
- [x] `// ---- P5: the overlay verbs' refusals ----` beside P4's: the two words, `parsePaneWord`
      (absent → -1 = session-wide; anything else refused naming both words and the absent form),
      every sentence of the table as a `static const char* const` / builder, the popup's five inline
      literals moved in unchanged. A comment beside `Session::overlay` (Task 2) points at this
      plan's vocabulary section for the rule; nothing paraphrases it.
- [x] `overlayCommandLine(cmd)`: the one command line both slots run — `powershell.exe -NoExit
      -Command "<A and C marks>; <cmd>; <capture $? then $LASTEXITCODE>; <D;<code> mark>"`, escapes
      as `[char]27` / `[char]7` so PS 5.1 and 7 both emit them; `openOverlay` uses it. The exit
      status rule of vocabulary bullet (c), in a comment.
- [x] `overlayExitOf(Session*)`: under `g_lock`, the FIRST `FfiMark` with `hasExit` → `exit N`,
      else empty. `g_lastOverlayExit` (string, `no overlay` at start and on every popup open) written
      from the popup's `WM_DESTROY` before its session is killed; `session overlay result` (bare) →
      `ctlOkStr(g_lastOverlayExit)`. Action `result` joins `open|close|resize` in the refusal.
- [x] `session.close` on a cover (a hidden target `splitOwnerOf` answers `nullptr` for): the cover
      sentence, nothing closed (the honesty check: the popup is still up, `g_overlaySession` still
      valid — `session text --target <its id>` still answers).
- [x] Honesty: the popup's `result` (`exit 3`, `exit 0`, `no overlay`, the reset on open),
      `session close --target <popup id>` refused; the existing overlay block still green.

### Task 2: the slot on the shell, its lifecycle, the surface seam
- [x] `Session::overlay` (`Session*`, null when none), `Session::overlayResult` (`std::string`,
      empty = `no overlay result`). `surfaceOf(Session* shell)`. `openPaneOverlay(shell, cmd)`:
      `newSession(cols, rows of the shell's grid, "powershell.exe", overlayCommandLine)`, `hidden`,
      name `overlay`, hung on `shell->overlay` under `g_lock`, then `syncPaneSizes` + invalidate
      when displayed; `closePaneOverlay(shell)`: read `overlayExitOf` into `overlayResult` and unhook
      under `g_lock`, kill the session outside it (the `closeSplitSide` order), `g_sel` cleared if it
      was the overlay's, invalidate, `emitEvent("tree")`.
- [x] The seam: `focusedSession()` returns `surfaceOf(g_sessions[g_pane[g_focus]])` (the popup
      override first, as today); `paint`'s loop paints `surfaceOf(...)` with the same pane index and
      draws the badge; `hitTest` reports the surface; `paneGridSize` / `syncPaneSizes` size the
      overlay to the same grid; `InvalidateCaret` and the wheel use the surface; `windowForSession`
      needs nothing (`g_hwnd`).
- [x] Lifecycle: `closeSessionAt` kills both panes' overlays first; `closeSplitSide` kills the
      victim's before the victim (the survivor keeps its own by the pointer exchange — a check);
      `OnPaneExit` reaches the same primitive; `closeFocused` closes the focused pane's overlay
      first; `callerWorkspace` walks overlay → shell → owner.
- [x] Honesty: the interactive-sibling checks, the surface reads (`active`, pane id, overlay id),
      swap, the three lifecycle paths, the chord, no orphaned host process.
- ➕ The verb's `--pane` arm for `open` / `close` / `result` landed here (the word read first, the
  two usage refusals, `pane not visible`, `pane overlay already open`, the agreement check in both
  flavours, `active` = the displayed session — not `focusedSession()`, which is the overlay when
  the focused pane is covered), so the honesty block had an opener. Task 3 adds `copy` / `text`,
  the overlay-id-without-`--pane` usage refusals, `paneOverlays`, the conformance probe.
- ➕ `dumpBufferRange` and `selectionText` read the live screen from the emulator
  (`emu_copy_grid`), not paintPane's snapshot (`s->grid`). The snapshot is refreshed only when
  THAT session is painted, so a shell under a pane overlay answered `session text --target <pane
  id>` with its last painted screen (stale after the promotion relaid it out) and an overlay on a
  session not on screen answered empty — both as ok. Pre-existing for never-shown split shells;
  found by the honesty block's first run (three FAILs), fixed at the reader.
- ⚠️ The pty-host's kill is `TerminateProcess` on the shell: a grandchild keeps running (a `ping`
  started from the overlay's PowerShell survived the slot's close by more than 10 s) — agwinterm's
  host, the same for every shell kill in lite (P3's `Stop-Ping` exists for it), no protocol change
  here. The honesty block's opener is therefore `echo <marker>; Start-Sleep 300` and its orphan
  oracle the overlay's own `powershell.exe`, found by the wrapped command line on it. Task 6's "no
  orphaned host process (`Get-Process`)" must count shells, not their children.

### Task 3: the verbs
- [x] `session.overlay` reads `pane` first (a bad word refused before any resolve); with a pane: the
      target may be the session id, either pane's id (the agreement check), either pane's overlay id
      (the overlay flavour), a name, `active`; `pane not visible` past the pane count; `open` /
      `close` / `result` / `copy` / `text` on the slot, each refusal from the block; `size-percent`
      present or `resize` with a pane refused before anything; without a pane: the popup arm as
      today plus `result` / `copy` / `text` on the popup (`copy` → `no selection` always, said in the
      skill). `--target <overlay id>` with `--pane` omitted names its slot (the rule).
- [x] `tree`: `paneOverlays` in slot order, present iff non-empty, beside the split block.
- [x] Conformance: `-Update -Url <#252 raw>`; the `$cliHasP5` probe and the `Needs-NewClient`
      rule; `-Strict` green with the dev CLI, SKIPs with the released one.
- [x] Honesty: every refusal of the table, `result` in its three states per slot, `tree` words,
      the raw-request refusals for `size-percent` / `resize` with a pane.
- ➕ `result --pane X` answers `overlay still running` and `no overlay result` as REFUSALS (agwinterm's
  PaneOverlayAction and #252's errors list both pin them so; task 2 had them as ok), and `exit N` as
  ok; the bare `result` stays ok in every state (agwinterm's `_lastOverlayExit`). `copy` / `text`
  answer `{"text": …}` on both slots already (the contract's `fields: [text]` step is in task 3's
  gate), so task 4 has only `--lines` / `--all` left.
- ➕ The overlay-id-names-its-slot rule applies to an EXPLICIT `--target <id>` only. An empty target
  and `active` resolve through `focusedSession()`, which is the overlay itself while the focused pane
  is covered — the first honesty run had a bare `session overlay close` (no target, the covered pane
  focused) close the pane overlay where the popup was meant, and `overlay text` read the pane
  overlay as the popup. The flag omitted means the session-wide slot, byte for byte; a program inside
  a pane overlay still reaches its own slot because the CLI sends the env id explicitly.
- ➕ `bingwintermctl.exe` (the released client fetched beside the exe) predates #226, so the
  conformance run without `AGWINTERMCTL` skips 20 steps and refusals, the four P5 ones among them,
  each naming the client's shortfall; `-Strict` with the dev CLI passes all 56 steps and every
  refusal. `check-contract` against `main` reports DRIFT until #252 merges (red by design).
- ➕ The drag inside a pane overlay auto-copies on release (lite's window convention, not the verb's):
  the honesty check saves the clipboard, sets a sentinel right before `overlay copy`, and pins that
  the VERB left it alone.

### Task 4: `text` with `--lines` and `--all`, on both verbs
- [ ] `dumpBufferTail(s, n)`: the last N lines of what `dumpBufferText` returns (one walk; no
      second copy of the row logic). `session.text`: `lines` (a whole number ≥ 1, else refused with
      agwinterm's `LinesRefusal` sentence) and `all` (bool); both present → `AllWithLines`.
      `session.overlay text` the same three through the same reader. `copy` → `{"text": …}`.
- [ ] Honesty: `session text --lines 3` is three lines, `--all` equals the bare form, the
      combination refused through a raw request; the same on `overlay text`.

### Task 5: docs, trackers, tests
- [ ] Skill: the overlay section rewritten around the two slots — the rule quoted from this plan,
      `--pane` on `open` / `close` / `result`, `copy` and `text` with their errors, the exit-status
      rule, the popup's `copy` answer, `session text --lines / --all`; the verb index; the env-ids
      bullet (a program inside a pane overlay holds the overlay's id); the old wording swept.
      `README.md` (verb count unchanged — no new `cmd ==` arm; the Scriptable bullet, the P2
      overlay paragraph, the Terminals bullet); `qa/panes.md` (the case + capture),
      `qa/control-honesty.md` (`overlay text` reads the overlay, `session text --target <pane>` the
      shell under it), `qa/selection.md` (a selection inside a pane overlay). agwinterm
      `docs/lite-parity.md`: the P5 entry → "Mirrored", the five differences of vocabulary bullet
      (a)–(e), the `session text` default under "What is deliberately different" — drafted in the
      notes below for the docs PR in the other repo after this merges.
- [ ] `check-contract` re-run against `main` once #252 is there; `run-all -Strict` green.

### Task 6: [Final] Verify acceptance criteria
- [ ] `test/run-all.ps1 -Strict` green with `AGWINTERMCTL` = the P5 dev CLI; `check-contract`
      green against #252's file; a sandbox split, a pane overlay on the right, a marker typed into
      the left, `PrintWindow` (the screenshot in the PR body); edge cases probed live (an untracked
      `.ralphex/p5-lite-edge-cases.ps1`, P4's shape): both panes covered then `swap`; the popup over
      two pane overlays; `split off` with the split shell covered; the shell under an overlay
      exiting; the chord; `--pane left` on a single pane then `split on` (the overlay stays on slot
      0, its grid follows); a horizontal split with `--pane left` (the TOP box); a window resize
      with a pane overlay up (its grid follows — `tree` cols/rows of the shell equal the overlay's
      `session text` width); a pane overlay on a non-displayed session then selecting it (drawn,
      focus where it was); `session text --all` on a pane with history; no orphaned host process
      after all of it (`Get-Process`).
- [ ] The plan's notes carry what each revmux round found (the P4-lite pattern).

## Technical Details

- **Why the slot hangs on the shell.** A pane is a `Session` in lite; the obligation the P4-lite
  plan recorded ("P5 must consult the slot map when it anchors an overlay to a pane") is met at ONE
  place — `paint` / `hitTest` ask `paneRect` for the box and `surfaceOf` for what to draw in it. A
  swap moves the shell's box and the overlay with it; a promotion exchanges whole objects. No map,
  no second source of truth.
- **Why in-window and not a second popup.** Gate 1: the rule's hard property is the sibling pane
  staying interactive, and a popup's `g_focusOverride` is a single global that takes every key.
  A popup is also framed, floats over the wrong place after a window move, and is raised only when
  the process holds the foreground — three ways to be "not the pane's box".
- **Why the popup stays a popup.** It is shipped, tested and recorded (P2-lite); a cover inside
  the content region would be a renderer rewrite for a slot the batch does not touch.
- **Why the exit code rides an FTCS mark.** The pty-host protocol carries no exit code (EOF is the
  only signal, `:1976`), the protocol is frozen for this batch, and the core already turns `OSC
  133;D;<n>` into `FfiMark::exitCode`. The wrapper is the same command line the popup used plus two
  writes; `session output` on an overlay works as a side effect.
- **Why `session text` keeps the whole buffer.** Gate 2; the skill promised it, the suites read
  markers from history through it, and `--lines N` gives a caller the screen when it wants one.
- **`copy` on the popup answers `no selection`.** The popup paints no selection and takes no drag
  (`paintPane(..., -1, ...)`, `hitTest` loops `g_pane` only) — the other half of the "selection"
  gap in `lite-parity.md`; a fix there is its own item, not this batch's.
- **No pane-overlay resize, no floating pane overlay** — agterm has neither; the box is the pane's.

## Post-Completion

- Sibling PRs: agwinterm `docs/lite-parity.md` (the P5 entry → Mirrored, the differences), the
  batch index's P5 line (mirror shipped).
- Release: lite's installer to **0.17.16** when Boris calls it; agwinterm 0.17.14 is what turns
  this PR's CI green.
- Review: revmux, two rounds minimum, a narrow round per fix commit.
- P6 onwards: the `capturedCommands` / `paneOverlays` pair is the node's per-pane shape; whatever
  the next batch adds per pane goes beside them, an array of words or an object keyed by pane id,
  as agwinterm emits it.
