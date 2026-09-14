# Configuration

Settings live in the registry under `HKCU\Software\agliteterm`; most of them are also on
*File ▸ Properties*. Key bindings and custom commands live in `%LOCALAPPDATA%\agliteterm\keymap.conf`
(see [commands and agent integration](agent-integration.md)), shell profiles in
`%LOCALAPPDATA%\agliteterm\profiles.json`.

## Settings over the control API

`config list` reports supported keys and current values; `config get KEY` reads one;
`config set KEY VALUE` saves only that registry value under `HKCU\Software\agliteterm` and applies it
to this instance. Other running instances are not changed; future launches read the saved values.
Unknown keys and invalid values refuse without changing settings. Writes also refuse while a modal
dialog is open or queued, protecting its unsaved edits. A timed-out request already executing reports
an unknown outcome: read back before retrying.

| Keys | Values |
| --- | --- |
| theme | auto, dark, light, classic (lite's UI modes, not the full app's theme catalog) |
| custom-colors, dos-palette, show-sidebar, show-toolbar, show-status, flag-view | true/false (also on/off or 1/0) |
| right-click-paste, copy-on-ctrl-c, copy-on-select | true/false (also on/off or 1/0) |
| foreground, background | #RRGGBB; used when custom-colors is true |
| sidebar-font-size | 0 for system default, or 6..24 |
| scrollback-lines | 0..1000000; default 5000; new surfaces only, no live eviction; positive caps allow 512 rows of batched-trim slack |
| omp-theme | a theme path for eligible new PowerShell shells, or `none` (see below) |
| restore-commands | true/false, default false (see below) |

`theme list/set` uses the same four modes. `settings` requests the Properties dialog without raising
the terminal; its reply is `settings open requested`. `keymap reload` reloads registry bindings:
deleted entries return to their default or unbound state, an explicit zero stays unbound.

With copy-on-select off, mouse release and finalize leave the clipboard alone; explicit Copy and
mark-mode Enter/Ctrl+C still copy. The registry escape hatches for the two default-on clipboard
bindings are `RightClickPaste` and `CopyOnCtrlC` (DWORD `0`).

Scrollback config affects the local replica, not the host's retained history, and is applied before a
new or adopted surface receives bytes.

Font face and size are chosen in Properties. There is deliberately no zoom: a raster face only exists
at the strike sizes its pack ships.

## Shell profiles

`profiles list` reads the current catalog; `profiles reload` validates
`%LOCALAPPDATA%\agliteterm\profiles.json` and replaces the catalog atomically. A missing file uses
detected shells in memory. Neither operation writes the file; malformed or unreadable reloads refuse
and keep the last good catalog. Startup logs malformed files and falls back to detected shells.

```json
{"default":"Build","profiles":[{"name":"Build","command":"cmd.exe","args":["/k"],"cwd":"C:\\src"}]}
```

- The New Session dialog, the `--profile NAME` startup switch and `session new --profile NAME` use
  exact names (ASCII-case-insensitive). Unknown or empty names refuse; command plus profile is
  ambiguous and refuses.
- An explicit cwd overrides the profile cwd. Running sessions keep their resolved launch spec.
- Supported profile fields are name, command, args and cwd. Nonempty env or icon, elevation and
  unknown fields refuse rather than silently doing nothing.
- Limits: names max 128 UTF-8 bytes; app and cwd max 259; at most 16 args, each max 2047 bytes; file
  max 1 MiB, 128 profiles.
- An empty argument array keeps PowerShell prompt integration; nonempty arrays are passed unchanged.
  Arguments containing control characters refuse, because the launch-state TSV format cannot preserve
  them.

## oh-my-posh

`omp list` discovers local `.omp.json` themes, first directory wins: `POSH_THEMES_PATH`, the normal
winget/scoop/chocolatey locations, then app-data `omp-themes`.

`omp set NAME [--persist]` requests initialization through the stock PSReadLine idle reader in
PowerShell 7 (PSReadLine 2.2.6–2.x).

- Completed input and previous completed switches are allowed; a nonempty editing buffer refuses
  without submitting or clearing the draft.
- Adopted, unsupported-reader, alternate-screen, readonly, exited and non-PowerShell panes refuse.
  Use `config set omp-theme` for future shells instead.
- A successful reply confirms that native initialization and its generated script completed. A
  claimed request without a timely result reports an unknown outcome; do not retry automatically.
- Persistence requires timely success, unchanged pane policy and no newer saved configuration.
- Theme content and OMP-generated shell code may execute commands; only apply themes you trust.

`config get/set omp-theme` reads or sets the path for eligible new PowerShell shells without
initializing existing ones; `none` clears it. Persisted initialization is not injected into adopted
shells or nonempty explicit profile argv. Paths must fit the host's encoded startup argument;
unsupported or overlong paths refuse. A live write followed by a persistence failure reports both
outcomes.

## Captured-command replay

`config set restore-commands true` opts into replaying captured commands (`K` records) on a future
fresh restore; the default is false. Review captured commands first. This does not immediately
execute anything in existing panes.

The same opt-in turns on the quit-time capture: closing the window fills each real pane's slot from
what that pane is running, so the replay has the close to work from.

Captured commands use legacy `K` records for ordinary lines and lossless `K2` records for tabs or
newlines; older builds ignore `K2` records. The API field is `capturedCommands` in either case. See
[restore capture](control-api.md#restore-capture) and [the state file](state-file.md).
