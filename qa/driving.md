# Driving a pane (P9)

Acquire the canonical suite token before live checks and retain it through verified restoration
and owned-process teardown. Use a sandbox instance with its own pipe/profile. Post messages only
to its HWND; never inject global input. Restart cases require the #48 ownership-safe cleanup.

## Input gate

`session readonly on|off|toggle|state|get --target ID` gates human input on that surface.
An omitted/active target means the focused surface, including a cover; an explicit shell id
means the shell beneath its cover. Keyboard, human paste and reporting mouse events are blocked.
Selection and non-reporting scrolling remain available. API `session type` and `session write`
and terminal protocol replies remain available. `session paste` refuses before clipboard access.
The flag resets on restart. Edit and palette offer Toggle Read-Only Pane; `Key_ReadOnly` is unbound.

Prove the blocked-input oracle with the same posted characters while off. Repeat on split,
overlay and popup surfaces, and reporting mouse click/motion/release/wheel. Check READ-ONLY in
status part 2 when changing focus. Use the #256 whole-format/sequence clipboard guard for any
clipboard check; do not replace arbitrary existing clipboard contents with a text-only snapshot.

## Persistence and replay

`session restore <command> --target PANE` pins a command; `none` clears. It requires an explicit
shell target. `session bind <agent-command> --target PANE` supplies a binding instead of the pin;
the default is `claude`, and `none` clears. Both save before success; a save failure is reported.
They are stored by pane role in R/B lines, with JSON-content escapes preserving command bytes.

Fresh restored shells receive their current binding, else their current pin, after one 2500 ms
delay. This is a delay, not a shell-readiness guarantee. The timer holds pane ids, not commands;
clearing/changing the value before it fires affects replay. Gone/exited/adopted shells are skipped.
K captured commands never replay; restore.capture's replayOnRestore stays false.

Required restart cases: pin only; binding wins over pin; adopted shell receives neither; clear,
change and close before the timer fires; split-role persistence and exact backslash/quote/tab
round-trip. Use an inert owned sink/marker command, not an actual agent launch.

## Geometry, switching and search

`session resize --split-ratio R` changes slot 0's share, clamped to 0.05..0.95. Grow arguments
move the divider in whole cells along its axis; wrong-axis or malformed arguments refuse before
mutation. Split ratios appear in the tree and G state lines. A swap preserves slot shares.

`session switch begin|advance|advance-back|commit|cancel` walks a snapshot of session recency.
The ordinary next/previous keyboard bindings still use tree order. Test A/C/B focus order,
cancel, commit, aliases, a removed snapshot member, one session and no sessions.

`session search QUERY --next|--prev|--close` searches the active surface. A target is accepted
for compatibility but does not redirect this v1 search. Matching is row-local, case-insensitive
using invariant scalar casing, with code-point-to-cell mapping for Cyrillic/CJK/astral glyphs.
Current matches use cyan frames; other matches use amber frames, leaving selection visible.
Matches/counts are as of the last search call. Paint revalidates row text and cell widths;
changed rows lose their stale highlight until the next call. Main-screen matches scroll into
view; alt-screen searches never scroll into history. There is no find bar or Ctrl+F binding.

Use PrintWindow to prove cell bounds, wide endpoints, stale-row suppression and removal on close;
also check FIND in status part 2. API assertions are in driving-cases.ps1 (control-honesty);
30 in-process Unicode/cell/field-codec checks are in driving.unit.ps1. These are not substitutes
for the mouse/popup/clipboard/pixel/restart acceptance cases above.
