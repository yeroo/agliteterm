# Commands, opt-in installers and agent lifecycle (P11)

P11 adds `command.list/run/leader`, `install.cli/hooks/shell`, `app.update` and
`claude.adopt/yolo/update`. These are control-pipe verbs. Use a CLI explicitly pointed at the lite
pipe; some shared agwintermctl versions execute `install cli` locally instead of calling the pipe.
For an unambiguous lite PATH installation, run the bundled `agliteterm-install.ps1 -Operation cli`
beside the intended `agwintermctl.exe`, or send `{"cmd":"install.cli"}` to the lite pipe.
No installation or permission-mode change happens automatically.

## Custom commands

Edit `%LOCALAPPDATA%\agliteterm\keymap.conf`, then `keymap reload`:

```text
command Build = dotnet build
command [new] Tests = dotnet test
command [overlay] Status = git status
command [detached] Editor = code "{AGW_CWD}"
leader = ctrl+k
map leader b = command:Build
map ctrl+shift+b = command:Build
```

`command run "Build"` matches a complete label, ASCII-case-insensitively. Unmatched raw text
defaults to a new PowerShell session; `--mode send|new|overlay|detached` overrides either default.
Send removes CR/LF and submits one line to the target; use it only when submission is intended.
New/overlay run in PowerShell; detached uses the system cmd.exe and returns a PID, not completion.
Readonly refuses send. New sessions stay interactive; pane overlays retain their result until closed.
Commands are also available in the palette and through actual configured chords.

`command list` returns label, mode, effective chord and text as tab-separated rows.
`command leader state|begin|cancel|key:CHORD` observes/drives a two-second leader state; Escape cancels.
Invalid files, undefined commands, duplicate labels, unknown actions/modes and oversized/non-UTF8
files refuse the whole reload and retain the last working catalog. Missing files clear the catalog;
reload never creates or rewrites the file. Lite accepts bindings only for its implemented actions.

Tokens are `{AGW_SESSION}`, `{AGW_SESSION_ID}`, `{AGW_WORKSPACE}`, `{AGW_CWD}`, `{AGW_PANE_ID}`,
`{AGW_PANE}` and `{AGW_APP}`. Unknown uppercase AGW tokens expand to empty. Values are also passed as
environment variables to launched processes, not injected into an existing send target's environment.
Pane roles use left/right slot vocabulary even for top/bottom splits; quick/scratch/overlay are explicit.
Tokens are textual substitutions, not shell escaping: quote expressions appropriately for your shell.
The native host's 2048-byte argument limit is checked before launch; oversized commands refuse.

## Installation and updates

`install.hooks` copies product-scoped status/notify/Claude/generic-agent scripts to lite app data,
merges four Claude hook events, and adds a named block to the current user's Windows PowerShell profile.
It preserves unrelated settings/hooks/profile text and custom PSReadLine Enter handlers. Notification
hooks only mark permission prompts blocked. The Codex notify script marks `agent-turn-complete`
completed; installation prints a user-level TOML line but never edits Codex configuration.
This follows the [Codex notify contract](https://learn.chatgpt.com/docs/config-file/config-advanced).

`install.shell` adds a product-scoped OSC-7 prompt wrapper to that profile. It does not rewrite the
PowerShell 7 profile. Installed scripts are inert outside `TERM_PROGRAM=agliteterm`.
`install.cli` adds the bundled CLI directory once to HKCU Environment Path; `--remove` removes matching
entries while preserving unrelated entries and the registry string kind. Open a new shell afterward.

Installers are opt-in, serialized and idempotent. Malformed/duplicate-key/deep JSON and corrupted
profile sentinels refuse before destination writes. Changed existing files get uniquely named `.bak`
backups via atomic replacement; output identifies completed writes and backups on a partial failure.
This is not a multi-file transaction. Updated text is UTF-8; original bytes remain in backups. Reparse
destinations refuse. Direct helper path overrides exist for isolated fixture tests, not the control API.

`app.update` queues the existing verified release updater only from its installed update channel.
Developer/portable copies and concurrent update requests refuse. A queued response does not mean
download, verification or installation succeeded. Nothing in P11 publishes a release.

## Claude adoption and restarts

`claude.adopt` with no target examines this window's real panes; an explicit target narrows it.
It requires a live, birth-verified descendant: native claude.exe, or node.exe executing the exact
absolute `node_modules/@anthropic-ai/claude-code/cli.js` path suffix, with one explicit UUID supplied through
`--resume`, `--session-id` or `-r`. Bare/continue/headless/fork-session, unknown or variadic flags,
inaccessible, ambiguous or unrelated
background descendants refuse. It never guesses the newest same-folder transcript. Existing bindings
are preserved; adoption does not interrupt input or enable permission bypass.

The opt-in Claude wrapper gives bare launches an explicit conversation UUID. Lite pane IDs are not
Claude UUIDs. A successful completed bare invocation can resume that conversation on the next bare
launch. Only bare calls, optionally with the explicit bypass flag, are decorated; every other argument
list passes through unchanged and does not change the wrapper's remembered UUID. Installation never
invokes the real CLI. Native adoption accepts conservative known option arities; identity-looking
option values are opaque. An initial positional prompt must follow the UUID and is never replayed.

`claude.yolo --target PANE` explicitly requests resume with `--dangerously-skip-permissions`.
It requires the per-process prompt bridge bundled into default PowerShell launches. Existing/adopted
shells and explicit-argument profiles must explicitly load `agliteterm-prompt.ps1` first. Unknown bridge,
custom conflicting binding, readonly, covered or ambiguous panes refuse without interruption.

While pending, a per-pane lease refuses editing input (including API type/paste); terminal protocol
replies remain available. The app sends one Ctrl+C byte only while the verified original agent
is alive, and authorizes resume only within 30 seconds. If Windows has not completed a canceled
interrupt I/O, the pane's lease remains reserved until completion is known; an event reports that
exception and no late resume is authorized. No global agent lock is held during that wait.
The shell claims a generated, quoted argv only at its `PSConsoleHostReadLine` boundary,
after all retained descendants exited, a new snapshot shows no surviving shell children, and the
shell reports itself as the sole attached console client (including late orphan checks). Resume
is returned to PowerShell's normal command pipeline, never executed inside the prompt or appended
to PSReadLine's draft. The prior readline function handles ordinary input unchanged; unsupported
alias/script readers are not replaced and do not register the bridge. State changes,
unknown ownership, timeout or missing claim mean no resume dispatch. No fixed-delay fallback or
name/PID-only process kill is used. Interrupt I/O has a bounded cancellable wait. Offers and acknowledgements
are retryable for the same globally unique authorization; the prompt checks expiry and executes it at most once,
including after a surviving shell is adopted by a new UI. A late receipt cannot replace a newer binding. Receipt
notification and binding persistence do not block authorization replies. An unconfirmed acknowledgement
is reported as such, never as completed startup. `agent.bridge` is the capability-checked shell integration protocol,
not a command API for callers to supply executable text.

`claude.update` owns its helper and descendants in a native kill-on-close job, assigned before the
helper starts. An owned pane overlay displays the update log; closing that viewer does not stop the
updater or release its exclusion. Closing the app terminates its owned update job and may leave a
partial update. The helper probes versions around `claude update`. Failed, unknown,
unchanged or older versions restart nothing and leave the overlay for inspection. A proven newer
version closes that completed overlay and requests safe restarts only for the window's originally
verified eligible panes using that executable/script. Each keeps its conversation and explicit startup
permission arguments; interactive permission-mode changes inside Claude cannot be inferred from argv.
Closed, changed, custom-bound or newly ineligible panes are skipped; new agents are not discovered
and interrupted after the update. The supervisor expires after five minutes without killing the updater.
It continues to exclude another update until the owned job has no active processes, even if the viewer
was closed; late completion never restarts agents. The log and version receipt are retained for inspection.

Replies say queued/opened, not completed. Read `agent.update` and `agent.restart` events for outcomes;
resume dispatch and binding persistence are distinct from successful agent startup. Receipt files in
the user's temp directory and failed/no-op overlays are retained as diagnostic evidence.

## Verification

Pure parser/input-gate and installer/updater fixture tests plus `selection-ui.ps1 -AgentIntegrationOnly`
cover the new surface. Live tests compile a private fake claude.exe, never invoke a real agent, and use
the shared suite token with retained-handle child teardown and clipboard/registry restoration.
The combined Strict suite runs only in disposable Windows CI. Delivery evidence is recorded separately
in `qa/p11-agent-integration.md`; a passing focused fixture alone is not the merge gate.
