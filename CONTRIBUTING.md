# Contributing to agliteterm

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

That C ABI carries **no compatibility guarantee across versions**: `src/main.cpp` requires exactly one
`kRequiredAbi`, and a mismatched pair refuses to load. While the client and the core lived in one
tree, a drift could only survive until the next rebuild; across two repositories it could survive a
whole release cycle and reach users. So the fetch reads the release's published ABI manifest and
**fails the build** on a mismatch, rather than letting it fail at load on someone else's machine.

To build against a core you are changing:

```powershell
./build.ps1 -NativeDir C:\src\agwinterm\native\target\release
```

### The control-API contract

`test/control-api.json` mirrors the canonical contract in agwinterm, `tools/check-contract.ps1`
compares them on every build, and both repositories run the same conformance steps in CI.

## Tests

```powershell
# Disposable CI only: the legacy aggregate suite is not yet safe on a shared desktop (#51).
./test/run-all.ps1
```

`driving.unit.ps1` compiles an in-process C++ harness for search cells, casing and command-field
decoding (MSVC required). Integration checks drive the **built exe** and assert on observable
behaviour: the diagnostics log, the state file, the control pipe, and the windows themselves.

Rules the suite obeys, each learned from a real incident:

- always a sandbox instance (`--pipe <name>`); never the default instance, which owns real state
- never inject global input (`keybd_event`/`SendInput`) — it lands wherever focus happens to be
- capture windows with `PrintWindow`, never `CopyFromScreen`, which grabs whatever overlaps

`restore-matrix.ps1` is the big one: cells covering kill vs. graceful close, two windows at once,
interrupted writes, `.bak` fallback, bogus apps, and old and future file formats.

The checks that drive the control pipe need `agwintermctl` — from `$env:AGWINTERMCTL`, from `bin/`,
or from an installed agwinterm, in that order. The fetch stages `bin/agwintermctl.exe` from the
release named by `cliTag` in [`native/pinned.json`](native/pinned.json), pinned apart from the core,
and refuses a staged copy that does not report that version. CI tests with that same binary. The
supervisor requires the real CLI before starting any suite and refuses if it is absent.

A check that needs a client newer than the pinned CLI (`cliTag`) probes the client first and SKIPs on
an older one; `-Strict` turns that into a failure, which is the release gate. The probed features:

- `--stdin`, a strict `--size-percent`, `sidebar width N`, the `caller` field — agwinterm #226
- `session context` and `restore capture` — agwinterm #233 (`agwintermctl restore` answers a usage
  line on a post-#233 client)
- `session split --axis`, `split close`, `swap` and `focus` — agwinterm #238 (`session swap x` is
  refused with "Nothing sent" by a post-#238 client)
- `session overlay --pane`, `overlay copy` / `text` and `session text --all` / `--lines` — agwinterm
  #250 (`session overlay resize --pane left` is refused before any pipe is opened)
- `session text --styles` — agwinterm #320 (`session overlay text --styles` is refused before any
  pipe is opened)

To try a CLI feature that no release carries yet, point `$env:AGWINTERMCTL` at an agwinterm dev build:
`<agwinterm>\src\Agwinterm.Ctl\bin\Release\net10.0-windows\agwintermctl.exe`.
