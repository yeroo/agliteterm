# Wave 3: HUD, quick, navigation and picker

P17 mirrors full agwinterm P13–P16 using native GDI and standard Windows controls.
Use a shared CLI built from full commit `7af9b0751aa73dc9e79b7e3de593e50bea76b331`
or newer. CI builds that pinned CLI after staging native dependencies. This change
does not update the native ABI pin or install/release a binary.

## Session HUD

`session hud open MESSAGE`, `session hud update MESSAGE` and `session hud close`
accept the owning session's exact ID, unique prefix or unambiguous name. Secondary
panes and quick/scratch/program-popup IDs refuse. A HUD is passive text, not a shell
or a terminal surface; explicit terminal reads/writes still reach their usual target.

Options: `--detail`, `--spinner` / `--spinner-style bar|braille|circle|blocks|dot|none`,
`--position` (nine top/center/bottom × left/center/right anchors), `--size-percent 1..100`
(bounded to 10..80), `--background-color` and `--text-color` (six hex digits, optional #).
Message/detail are NFC-normalized and limited to 256 Unicode scalars, rejecting C0/C1
controls; message must be nonblank. Native GDI wraps/clips within the content region.
Update replaces options except the original background. Open replaces a HUD. The
ordinary close action and `session overlay close` dismiss a HUD before closing a pane.
A session-wide program popup replaces its captured owner's HUD; HUD open/update
refuse that slot while the program popup exists. HUD close never kills a program.
Pane overlays can coexist. HUD state is reported in `tree`, never restored.

## Quick terminal

One quick popup **per lite process**, not the full app's process-wide multiwindow broker.
`quick on|off|toggle` uses the pointer monitor's work area, width and height both
`quick-terminal-size` percent (40–90, default 70). API show is nonactivating and pinned;
human Ctrl+backtick show requests normal OS activation and hides on focus loss.
Hiding retains its shell; shell exit destroys the popup and the next show launches
a fresh shell in the user's home directory. It is excluded from library tree/restore.

`quick-terminal-hotkey` defaults disabled. Set it through `config set` to Ctrl/Alt
with an optional Shift and a letter/digit/F1–F11/backtick. Win/F12 and unmodified keys
refuse. Native registration reserves a new ID before saving or releasing the old one;
conflict/save failure preserves the old binding. No global key is installed by default.

Use `session type/text/write/... --window quick` for content. Hidden quick refuses
that selector; library creation/navigation/split/restore operations refuse it rather
than affecting the library underneath. Quick shells export `AGWINTERM_WINDOW_ID=quick`.
Other explicit window selectors must resolve this process's exact/unique instance;
address another library's pipe explicitly. No cross-process broker is implied.

## Navigation and cursor

`workspace go next|prev` wraps, includes collapsed and empty workspaces, and refuses
flagged/focused-workspace modes or fewer than two workspaces. Empty navigation changes
the creation destination without replacing the displayed terminal. Selecting a session
restores its workspace as current. Collapse/expand survive tree refresh, not app restart.

Keymap actions: `next_workspace`, `previous_workspace`, `toggle_workspace_collapse`.
`map f5 | f7 = next_workspace` binds alternatives; invalid alternatives reject the
whole catalog and retain the previous one (lite's existing atomic-file rule). Pipes
inside command text remain command syntax. Native tree tooltips reveal truncated names
and request 600-pixel word wrapping; Windows may exceed that width for an unbroken word.
This is not full's custom client-clipped tooltip renderer.

`foregroundShells` lists conservative shell-name/null observations in pane order;
known primary/split names also appear as `foregroundShell` / `splitForegroundShell`.
Only recognized root shells with matching process birth identity and no observed child
are named. Queries run without the UI lock. Builtins can be busy without a child:
**these snapshots never prove prompt readiness, and write acknowledgements never prove execution**.

Config keys: `cursor-style` bar/beam/line, block/box, underline/underscore;
`cursor-blink` true/false/on/off/yes/no/1/0; `cursor-blink-ms` positive 32-bit integer.
Defaults bar, true, 530 ms. DECSCUSR overrides shape and blink. Raster-font zoom and
images remain unsupported; native control accessibility is not terminal UIA parity.

## Native picker

Pipe UTF-8 lines or JSON `[{"id":"a","label":"Alpha","subtitle":"Read only"}]`
into `agwintermctl pick --no-block`; `pick result ID` polls; `pick cancel ID` cancels.
Use `--input-format lines|json|auto`, `--prompt`, `--query`, `--allow-custom`, optional
`--follow` for normal OS activation. Without follow, no foreground is taken.

One pending picker per process; EDIT/LISTBOX/Select/Cancel controls own keyboard,
mouse and drop input on the library owner. Explicit terminal API writes are independent.
Labels alone are searched with weighted prefix/substring/subsequence matching; blank
query preserves input order, ties use case-insensitive ordinal label then input order.
Custom requires a nonblank unmatched query and returns its trimmed value.

Bounds: 1000 items, 4096 UTF-16 units per field, 1 MiB request, 64 Mi total label units
times distinct terms per filter. An over-complex edit disables selection until corrected.
IDs are opaque, exact, unique; labels nonempty; display fields reject C0/DEL.
One pending exact ID, eight completed answers retained in originating-process memory.
Result IDs do not follow moving window selectors; poll the originating pipe. Process
exit loses answers: there is no full-app cross-window closed-owner retention in lite.

Wire uses normal envelopes: open `{id}`, result `{pick:OUTCOME}`, cancel `cancelled`.
CLI no-block/result print payload JSON even with `--json`; cancel uses the ordinary
envelope with `--json`. Outcomes: pending (exit 1), picked `{id,label,index}` (0),
custom `{query}` (0), cancelled (2). Index is original input order. Retained cancellation
cannot overwrite a choice. Queued open times out after 10 seconds and is withdrawn;
in-flight construction rolls back. If the successful open reply is lost before its
ID reaches the caller, Escape/Cancel is the recovery; no exactly-once delivery claim.

## Verification

`test/wave3.unit.ps1` is headless. `test/selection-ui.ps1 -Wave3Only -TokenOwner NAME`
uses the canonical token and owned cleanup; no existing lite/host is adopted or killed.
Full `test/run-all.ps1 -Strict` and global-focus checks belong in disposable CI only.
