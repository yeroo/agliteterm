# Selection

What happens to a selection while the buffer moves under it, and what Ctrl+C does over it.

**The rule:** the highlight and the clipboard read the same cells, so what lands on the clipboard is
always what is visibly highlighted. A selection follows its text through scrollback eviction and
dies with its own lines; it never survives a change of screen, because the alt screen is a different
buffer and an index into one names unrelated text in the other.

The agwinterm sibling of this file carries more cases — mark mode, Select All, drag-autoscroll, a
`scrollback-lines = 0` case — because lite has none of those features. See `qa/product.md` for the
differences that are deliberate.

Setup for every case: sandbox instance per `qa/product.md`. Fixtures print **distinct** text per
line — with identical lines a selection that slid onto other rows compares equal to the original and
passes, which is the exact defect being tested for.

---

## A drag makes a selection, and it follows its text when output scrolls

**Guards:** output used to wipe the selection, which made Ctrl+C-copies useless next to a running
agent: the agent prints, the selection is gone, Ctrl+C interrupts and cancels its turn. Boris, on
0.17.5: *"when I select text in lite, I expect ctrl+c will copy it not send break sequence"*.

**Setup:** run `qa/fixtures/marker.ps1` (40 rows of `MARKER-<n>-xxxxxxxxxxxxxxxx`).

**Steps:**
1. Drag (300,150) → (900,400).
2. Record what `session copy` returns.
3. Run `qa/fixtures/noise.ps1`, wait for it to finish.

**Expect:** non-empty at step 2, and the *same* string at step 3. Non-empty **and** equal — two empty
strings compare equal, so a drag that selected nothing would otherwise pass while proving the
opposite.

**Fails when:** `syncSelection` stops shifting by `evicted`, or the reader thread starts clearing
`g_sel` on output again.

---

## A selection dies with its lines when they are evicted

**Guards:** buffer-absolute rows renumber when eviction drops the oldest lines. A selection that
ignores that keeps naming the same numbers while the text under them moves, so the highlight and
`session copy` quietly return something the user never selected — worse than losing it, because
nothing looks wrong.

**Setup:** `marker.ps1`, then a drag as above.

**Steps:** run `qa/fixtures/flood.ps1` (6000 rows, past the core's 5000-line cap plus its
batched-trim slack, so eviction really happens). Wait ~25s.

**Expect:** `session copy` returns empty.

**Fails when:** the `min(aRow, bRow) < ev` drop in `syncSelection` is removed, or `s->evicted` stops
being fed.

---

## Crossing into the alt screen drops the selection

**Guards:** a full-screen app starting up is the common case; the highlight would otherwise sit on
top of its UI and copy that.

**Setup:** `marker.ps1`, then a drag as above.

**Steps:** run `qa/fixtures/althold.ps1`, which enters the alt screen and **holds** it for 6s. (Typed
as two separate commands, the shell's prompt redraw lands in between and the buffer is back before
the check runs — the case would then pass for the wrong reason.)

**Expect:** `session copy` returns empty while the alt screen is up.

**Fails when:** the `ai.isAltScreen != g_sel.alt` drop at the top of `syncSelection` is removed.

---

## A drag inside a repainting TUI builds a selection and keeps it

**Guards:** codex and Claude Code repaint about once a second. agwinterm dropped any selection in a
buffer whose shifts it could not measure as soon as output arrived, which fired mid-drag and made
selection impossible there (fixed in agwinterm 0.17.7). lite never had that rule — this case exists
so it never acquires one.

**Setup:** run `qa/fixtures/tui.ps1` — alt screen, 25 distinct `BODY-<n>` rows, a status line
repainting every second, which after 14s blanks the body and idles.

**Steps:** drag (300,150) → (900,300); read `session copy` immediately and again after ~5s.

**Expect:** non-empty both times, the same both times, containing `BODY-` rows, and its first
non-blank line appears in `session text`.

**Fails when:** `syncSelection` starts dropping on output, or `hitTest` and `paintPane` stop using
the same offset.

---

## Ctrl+C over that selection copies instead of interrupting

**Guards:** the report this whole area came from.

**Steps:** put `SENTINEL` on the clipboard, send Ctrl+C, wait 2s.

**Expect:** the clipboard holds exactly what `session copy` returned. Not `SENTINEL`.

**Skips when:** the machine has no usable clipboard — say so; a skip is not a pass.

**Fails when:** the `g_copyOnCtrlC && live` branch stops consuming the key.

---

## Ctrl+C over a blank selection reaches the app, and leaves the clipboard alone

**Guards:** a live selection can hold no text — a TUI repaints and blanks the cells under it. Then
there is nothing to copy and Ctrl+C must reach the app, or the user loses the interrupt with nothing
to show for it. The trap is that `selectionText` joins its rows with `\r\n` whether or not a row
contributed a character, so a blanked six-row selection is ten characters of pure separator: any
test by *length* reads it as a successful copy. That is exactly how agwinterm's first fix
reintroduced its own bug (found by review, fixed in 0.17.7), and lite gated on `g_sel.has()` alone
— the selection EXISTING — which has the same effect.

**Setup:** `tui.ps1`, ~14s in, after it has blanked its body. Drag (300,150) → (900,300) over the
now-blank rows.

**Steps:** confirm `session copy` returns nothing but whitespace; put `SENTINEL` on the clipboard;
send Ctrl+C; wait 3s.

**Expect:**
- the clipboard still holds `SENTINEL`;
- the interrupt reached the app. Observe it by the fixture's counter **freezing**, not by the alt
  screen going away: an interrupted script never reaches its own `?1049l`, so the alt screen stays up
  either way. Read `blanked (\d+)` from `session text`, wait 4s, read again — equal means killed.

**Fails when:** the Ctrl+C branch goes back to testing that a selection exists, or `copySelection`
decides "copied something" by string length.

---

## Scrolling back inside a full-screen app copies what it shows — MANUAL

**Guards:** a deliberate DIFFERENCE from agwinterm, recorded so nobody "fixes" it by copying the
other product. `paintPane` composes the history tail above the live grid through `scrollOff`, and
`hitTest` maps clicks through the same offset — on *either* screen. So if the view is scrolled, the
highlight and the copy move together. agwinterm instead pins the offset to 0 on the alt screen, and
had a bug where only its renderer did: the highlight and the clipboard disagreed, and Ctrl+C copied
rows the user could not see.

**Why manual:** the harness cannot scroll a full-screen app's view. A posted `WM_MOUSEWHEEL` does not
reach lite's handler, and Shift+PageUp does not scroll while the alt screen is up (verified on
0.17.11 — worth its own question, but it is not this case's subject). So drive it with a real wheel.

**Steps:** run `qa/fixtures/marker.ps1`, then `qa/fixtures/tui.ps1`. Wheel up until `MARKER-` rows
are visible, then drag across them and read `session copy`.

**Expect:** what the copy returns is what is highlighted on screen. Both showing history is fine;
one showing history while the other shows the TUI is not.

**Fails when:** `hitTest` and `paintPane` stop deriving their row from the same `scrollOff`, in
either direction.

**Automated part:** with the view NOT scrolled, the agreement invariant still holds and is covered by
the TUI case above. If you cannot scroll, report this case SKIP — never PASS on the un-scrolled path,
which checks nothing this case is about.
