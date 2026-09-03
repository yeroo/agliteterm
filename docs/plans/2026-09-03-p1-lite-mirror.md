# P1-lite — mirror the read-only trio: `surface.cursor`, `statusChangedAt`, a truthful `ping`

The agliteterm half of batch **P1** of the parity programme (agwinterm
`docs/plans/2026-09-03-parity-batches.md`). agwinterm shipped its half in PR #221 on 2026-09-03; the
two products now advance **batch by batch**, so this lands right behind it rather than waiting for
the wave-2 catch-up (P8) the index originally planned.

## Overview

Three small, **read-only** additions to the control API, the same three agwinterm just shipped, so
an agent written against either product gets the same answers:

- **`surface.cursor`** — the caret column of a pane, as a **bare integer**. It is the last check
  before typing into another agent's composer: the caret rests at a known column in an empty box, so
  a *different* column means a draft is sitting there and the send must refuse. agwinterm's reply is
  `{"ok":true,"result":<int>}` with the column only (agterm's shape; the row is deliberately not
  reported). lite must answer identically — the conformance contract pins it as an integer.
- **`statusChangedAt`** — epoch seconds recording when a session's status was last **written**,
  reported on every session node of `tree`, always present. `tree` says `"status":"active"` with no
  age, so nothing can tell a working agent from one whose hook died forty minutes ago.
- **a truthful `ping`** — `agwintermctl version` (new in agwinterm #221, and it is agwinterm's CLI
  that both products are driven with) reports the app serving the pipe from `ping`'s reply. lite's
  `ping` answers the hard-coded string `"agliteterm 0.1"` (`src/main.cpp:6182`) whatever version is
  running, so `version` would name a build that does not exist. There is no lite-side `version` verb
  to add: fixing `ping` IS the mirror of task 3.

What agwinterm decided, and lite must match (each is a contract, not a style):

- `surface.cursor` reports the **column only**, bare integer, JSON number — not `{"col":N}`, not a
  string. Column `0` is a real answer, not "no answer".
- `statusChangedAt` is stamped on **every** `session.status` write, including a re-assert of the
  same status. The question callers ask is "is this agent's hook still alive", and a hook
  re-asserting `active` every 30 s is precisely the liveness signal — collapsing repeats would
  report the age of the *first* write and make a healthy agent look dead. This is the one decision
  someone will later mistake for a bug; put the reasoning in a comment where the stamp is written.
- `statusChangedAt` is seeded when the session is created, so a session whose status was never set
  reports its own age rather than `0`; and it is emitted **always**, not only when non-default.
- Targeting is whatever `resolveTarget` already does — the pane you check is the pane
  `session text` / `session type` reach. lite has no multi-pane sessions, so the "session name
  reaches the focused pane" asymmetry agwinterm documents does not arise here; do not invent it.

## Context (from discovery)

- `src/main.cpp:6176` — `ctlDispatch`, the verb switch. `:6182` `ping`; `:6183` `tree` (builds each
  session node by hand with string concatenation — `statusChangedAt` is one more field there);
  `:6359` `session.status` (writes `target->status` and emits the `status` event — the stamp goes
  beside that write).
- `src/main.cpp:6272` — `Session* target = resolveTarget(req.get("target"), &targetWhy)`; the
  resolved-target verbs (`session.text` at `:6355` is the shape to copy: refuse with `targetWhy`
  when null, otherwise answer).
- `src/main.cpp:299` — `struct Session`; `:301` `std::string status = "idle"`. The new field lives
  beside it, initialised at construction.
- `src/main.cpp:74` — `FfiEmuInfo { cols, rows, cursorRow, cursorCol, ... }`, filled by `emu_info`
  (`:1204`); `completedMarks` at `:1400` is a small model of reading it **under `g_lock`**. The
  renderer reads `info.cursorCol` at `:3118` — same source, so the number `surface.cursor` reports is
  the caret the user sees.
- `src/main.cpp:5832` — `updVersion()`, the compiled version the About box shows. `ping` should say
  `"agliteterm " + that`, the way agwinterm's `ping` says `"agwinterm " + AppVersion()`.
- `src/main.cpp:6144` — `installAgentSkill` writes `kSkillMarkdown`. It documents **only** the verbs
  lite implements and names the refused ones, deliberately (a skill that overpromises made Claude
  Code look broken once). The new verbs go in; agwinterm's wording for them is in its
  `src/Agwinterm.Pty/AgentSkill.cs` — borrow the caveats, not the multi-pane parts.
- `README.md` — the agwintermctl section lists the verbs lite answers.
- `test/control-api.json` — lite's copy of the contract; `tools/check-contract.ps1` compares it with
  agwinterm's canonical copy every build. `test/conformance.ps1:96` `Test-Shape` knows
  `string` / `object` / `array` only — a bare-integer reply needs a new kind.
- `test/*.ps1` + `test/ui-lib.ps1` (`Start-Sandbox`, `Send-Ctl`, `Get-CtlResult`, `Get-PaneText`)
  — the checks drive the BUILT exe through the real `agwintermctl` against a sandbox instance;
  `test/run-all.ps1` lists which ones run. `test/ctl-path.ps1` resolves the client.
- `qa/product.md` (the adapter: sandbox instance, throwaway `%LOCALAPPDATA%`, no global input),
  `qa/selection.md`, `qa/panes.md` — the markdown QA cases and their style.
- agwinterm's tests for the same verbs, for the cases worth mirroring:
  `tests/Agwinterm.Pty.Tests/SurfaceCursorTests.cs`, `StatusChangedAtTests.cs`; its QA cases in
  `qa/control-read.md`.

## Constraints

- **The contract change is agwinterm-first.** `test/control-api.json` here must end up
  byte-for-byte (modulo line endings) what agwinterm's `tests/conformance/control-api.json` will
  say; the identical step is being added there in a sibling PR and merges before this one. Add the
  step here as specified in task 4 and do not improvise its shape — if the runner cannot express
  something, extend the runner (`Test-Shape`), not the step.
- **Read-only.** No verb in this batch may mutate a session, the state file, or the UI.
- Same reply envelope as everything else: `ctlOk` for a value that is already JSON, `ctlOkStr` for a
  string, `ctlErr` for a refusal. A bare integer goes through `ctlOk(std::to_string(col))`.
- Read the emulator **under `g_lock`**, as every other reader does.
- Cross-cutting safety rules for anything that drives a live app are in `qa/product.md` and apply
  in full: sandbox instance (`--pipe <name>`, throwaway `%LOCALAPPDATA%`), never `keybd_event` /
  `SendInput`, `PrintWindow` never `CopyFromScreen`, never the real user profile.
- Build with `./build.ps1`; the checks need the built exe. The core is not touched — no ABI
  movement is expected, and a change there means something went wrong.

## Testing Strategy

- **PowerShell checks** in `test/` against a sandbox instance: this is where verb shape, targeting
  and refusals are pinned, and where "the number is *right*" gets checked — a cursor column that is
  always `0` passes a shape test.
- **Conformance** (`test/conformance.ps1`) pins the cross-product contract.
- **QA cases** in `qa/` for the parts that need eyes: the caret the verb reports is the caret the
  window paints.
- Each task's checks must pass before the next task starts.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope

## Implementation Steps

### Task 1: `surface.cursor`
- [x] add `surface.cursor` to `ctlDispatch` beside the other resolved-target verbs: refuse with
      `targetWhy` when the target does not resolve; otherwise read `FfiEmuInfo` under `g_lock` and
      answer `ctlOk(std::to_string(info.cursorCol))` — the **column only**, a bare JSON integer
- [x] a pane whose child has exited still reports its caret (a dead child does not un-address the
      pane, and a caller deciding whether to type must get a number, not an error); a session that
      is gone from the tree is refused. Pin both
- [x] comment on the verb: why column-only (agterm's shape, shared with agwinterm), why row is not
      reported, and that the target resolves exactly as `session text` / `session type` do
- [x] `test/control-read.ps1` (new, listed in `run-all.ps1`): a fresh pane reports the prompt's
      column and **not** `0` mistaken for "no answer"; type text without Enter and the column moves
      by that many cells; an unknown target returns `ok:false`; the reply is a JSON **number**
      (`[int]` after `ConvertFrom-Json`, not a string); a pane whose shell has exited still answers
- [x] a case for the deferred wrap: after printing into the last column the answer equals the pane
      width, so callers must not use it as an index without clamping — assert the value, document
      the caveat where the verb is documented
- [x] build + run `test/control-read.ps1` — must pass before task 2
- ⚠️ the published agwinterm release (v0.17.8, 2026-09-02) predates #221, so the fetched
      `bin\agwintermctl.exe` has no `surface cursor`. `test/control-read.ps1` detects that and
      SKIPs (fails under `-Strict`); locally run it with `$env:AGWINTERMCTL` pointing at a
      post-#221 build. It goes green in CI when agwinterm cuts its next release — the same
      merge gate as `check-contract`, not a bug to work around

### Task 2: `statusChangedAt`
- [x] add `long long statusChangedAt` (epoch seconds) to `struct Session`, initialised at
      construction — never `0` for a live session
- [x] stamp it in `session.status` on **every** write, including a re-assert of the same status,
      with the liveness reasoning in a comment (see Overview). Restored sessions get a fresh stamp
      at restore time — a stamp from a previous run would describe a hook that is not running
- [x] emit `"statusChangedAt":<epoch seconds>` on every session node in `tree`, **always** — a
      consumer that has to distinguish "absent" from "old" gains nothing from an omission
- [x] `test/control-read.ps1`: the field is present and plausible (within a minute of now) for a
      session that never set a status; setting a status makes the age small; back-dating is not
      available from outside, so prove the re-assert rule with time: set `active`, wait 2 s, set
      `active` again, assert the stamp **moved forward** (equal would mean repeats are collapsed)
- [x] build + run `test/control-read.ps1` — must pass before task 3

### Task 3: a truthful `ping`, and what `agwintermctl version` sees
- [x] `ping` answers `"agliteterm " + <compiled version>` (`updVersion()`), not `"agliteterm 0.1"`
- [x] `test/control-read.ps1`: `ping` names the product and the version the build printed (the
      installer's `AppVersion`); `agwintermctl version --pipe <sandbox>` reports that string as the
      app and exits 0 — this is the only lite-side check `version` needs, since the CLI is
      agwinterm's
- [x] build + run — must pass before task 4

### Task 4: the contract, the skill, the docs
- [ ] `test/conformance.ps1` `Test-Shape`: add an `integer` kind — the result must be a whole
      number, not a string, not a float, not null. Mirror the exact same edit into the copy of the
      runner's comment header if it enumerates kinds
- [ ] `test/control-api.json`: add, immediately after the `session.text` step, this step and
      nothing else:
      ```json
      {
        "verb": "surface.cursor",
        "args": ["surface", "cursor", "--target", "{alpha}"],
        "result": "integer",
        "note": "the caret COLUMN of the pane, bare, as agterm reports it. Row is deliberately absent; a caller checking 'is that composer empty' compares one number. Value is not compared: it is a shell prompt's width."
      }
      ```
      and bump the verb count in the file's `$comment` by one. `tools/check-contract.ps1` will fail
      until agwinterm's copy carries the same step — that is expected and is the merge gate, not a
      bug to work around
- [ ] `kSkillMarkdown` (`installAgentSkill`): document `surface cursor` (what the number means, the
      "different column = draft, do not send" rule, the wrap caveat, and that the same column is
      necessary but not sufficient — a draft exactly one wrap width long parks the caret where it
      started, so back a match with `session text` of that row), `statusChangedAt` in `tree` (age
      of the last status **write**; a re-assert moves it), and `agwintermctl version`
- [ ] `README.md` agwintermctl section: the same three, in the section's existing voice
- [ ] `qa/control-read.md` (new, `qa/selection.md`'s style): one case proving `surface.cursor`
      tracks the painted caret — feed a known prompt, compare the column with what a `PrintWindow`
      capture shows at the caret cell after typing more; one case for `statusChangedAt` going back
      **down** after a re-assert; one for `version` naming the sandbox's pipe and product
- [ ] build, run `test/run-all.ps1` (expect `check-contract` to be the only red until the agwinterm
      side merges; everything else green) — must pass before task 5

### Task 5: [Final] Verify acceptance criteria
- [ ] verify every requirement in Overview is implemented, and every "what agwinterm decided" line
      holds in lite — check each against the code, not the plan
- [ ] verify the edge cases: target by id prefix; target by name; an ambiguous name is refused, not
      guessed; the split pane (`session split`) reports its own caret, not the primary's; the alt
      screen (a column is a column — assert no special-casing crept in)
- [ ] `git diff` on `native/` is empty and the build printed the same ABI as before
- [ ] run `test/run-all.ps1 -Strict` and the QA cases against a sandbox build
- [ ] agwinterm's `docs/lite-parity.md` is the tracker for this gap and lives in the other
      repository — do NOT edit it here; note in this plan's ⚠️/➕ section what it should say
