# agliteterm — QA adapter

How the `ui-qa` skill brings this product up, drives it and observes it. The cases in `qa/*.md`
assume everything here.

agwinterm has the same layout (`qa/` + `ui-qa`), and the terminal-behaviour cases are deliberately
close to each other — where the two products differ on purpose, the case says so.

## Build

```powershell
./build.ps1
```

The core comes from a published agwinterm release, named in `native/pinned.json`. Two traps:

- **`"tag": "latest"` plus a cache that is never invalidated.** `tools/fetch-native.ps1` skips any
  asset already in `.native/<tag>\`, so once `latest` has been fetched, a *newer* agwinterm release
  is never picked up. The symptom is an ABI mismatch naming an old number ("requires abi 16 but
  publishes abi 15") on the day after the release that fixed it. Fix: `Remove-Item -Recurse -Force
  .native\latest` and build again.
- To build against an **unreleased** core, `./build.ps1 -NativeDir <agwinterm>\native\target\release`.

`bin\agliteterm.exe` is the only output; its version is printed at the end of the build. There is no
second output root here — that trap is agwinterm's.

## Launching an isolated instance

Unlike agwinterm (a .NET app, where a `%LOCALAPPDATA%` override is ignored because .NET resolves the
known folder), lite is plain Win32 and reads the environment, so an override **does** isolate it:

```powershell
Start-Process $exe -ArgumentList @('--pipe', 'qa1', '--no-restore') `
    -PassThru -Environment @{ LOCALAPPDATA = $throwawayDir }
```

`Start-Sandbox` in `test/ui-lib.ps1` does that, waits for the control pipe, un-maximises and places
the window at a **fixed 1100x700 at (150,100)** — every coordinate in every case is client-relative
to that.

**Settings live in the registry**, `HKCU\Software\agliteterm`, and that is NOT isolated by the
environment. A case that needs a setting changed must save the value first and restore it in a
`finally`, and must say so. Most cases here need no setting at all.

## Driving input

`test/ui-lib.ps1` defines `[LiteUi]` — `PostMessage` to the sandbox window only, never global input:
`Drag`, `Click`, `Wheel`, `Key`, `Chord` (Ctrl(+Shift)+key, which attaches to *this instance's* input
queue so `GetKeyState` sees the modifier).

## Observing

The same `agwintermctl` the full app uses, resolved by `test/ctl-path.ps1` — that is the point:
"agliteterm speaks the agwintermctl dialect" is only true if the real client proves it.

| helper | verb |
| --- | --- |
| `Get-PaneText $s` | `session text` |
| `Get-PaneSelection $s` | `session copy` |
| `Send-Ctl $s @('session','type', "text`r")` | `session type` |

**Clear `AGWINTERM_SESSION_ID` / `AGWINTERM_PANE_ID` / `AGWINTERM_PIPE` before every ctl call.**
`Send-Ctl` does. A QA run is started from inside an agwinterm pane, so those are set, and a verb with
no `--target` resolves *the caller's* session — against the sandbox that session does not exist, so
`session text` comes back empty and `session type` is accepted and discarded, with no error. A suite
can go green having driven nothing; it happened while writing agwinterm's copy of these cases.

## Where lite differs from agwinterm, on purpose

Cases must not assume the main app's behaviour. As of 0.17.11:

- **No mark mode, no Select All, no drag-autoscroll.** Those cases exist only in agwinterm's `qa/`.
- **Scrollback is not configurable** — lite does not call `agwcore_emu_set_scrollback` yet, so there
  is no `scrollback-lines = 0` case here.
- **The alt screen scrolls back into main-screen history.** `paintPane` composes the history tail
  above the live grid using `scrollOff` on *either* screen, and `hitTest` maps clicks through the
  same offset. So wheeling up inside a full-screen app shows real scrollback, and a selection there
  copies what is displayed. agwinterm pins the offset to 0 on the alt screen instead, and had a bug
  where only the renderer did — highlight and clipboard disagreed. Here they agree, so this is a
  difference, not a defect. Recorded as a MANUAL case: neither a posted `WM_MOUSEWHEEL` nor
  Shift+PageUp scrolls the view while a full-screen app is up (0.17.11), so the harness cannot get
  there — a real wheel can.

## What is here, and what is still a script

`qa/selection.md` holds the selection cases. **Clipboard and host actions stay in
`test/clipboard.ps1`** — OSC 52 writes, query replies, right-click paste while a TUI holds the mouse
— because CI runs `test/run-all.ps1 -Strict` and those checks would lose their only automated home
until the markdown cases have a CI story. Port them when that exists, not before: coverage that runs
on every push beats coverage that runs when someone remembers.

## Also worth running before a PR

```powershell
./test/run-all.ps1 -Strict     # log/restore/migration/conformance/clipboard/agbf
```
