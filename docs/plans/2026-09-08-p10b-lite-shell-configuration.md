# P10b-lite — shell configuration

Codex-owned worktree `agliteterm-p10b`, branch `feat/p10b-lite-shell-configuration`, based on
P10a candidate `32f0d4a`, now merged as `7e2f44a` (#54); its parity update merged as `78f47e8` (#261).
Claude remains unavailable; use Codex-only revmux.

## Scope and boundaries

- Custom `profiles.json` catalog, `profiles.list/reload`, and consistent exact-name selection in
  the New Session dialog, startup `--profile`, and `session.new --profile`.
- `restore-commands` defaults false. When enabled, fresh restored panes may replay their captured
  K slot; explicit binding B wins over pin R, which wins over K. Never replay into adopted shells.
- `omp.list/set`: discover local themes and explicitly request initialization in an eligible
  PowerShell pane, with truthful write/persistence outcomes. No download/install or profile edits.
- Font changes require resolving Boris's existing no-zoom rule. Preserve it until that decision;
  this is not permission to pretend global font changes target only one pane.

## Profiles

Store under the existing redirected app-data directory, never a second real-user location. The
JSON shape is `{ "default": "NAME", "profiles": [{ "name": "NAME", "command": "EXE",
"args": ["ARG"], "cwd": "DIR" }] }`. Names are unique ignoring ASCII case, matched exactly,
not by substring. A missing default, duplicate property/name, wrong type, invalid UTF-8/escape,
embedded NUL, oversized field/file or unsupported property refuses the entire reload.

The launch-compatible first catalog supports name/command/args/cwd. Nonempty env/icon and elevated
profiles are not supported in this batch and must refuse explicitly, not disappear silently.
The current host has only two spare environment slots and saved launch specs do not retain env;
that needs its own transport/state design. Empty optional canonical fields may be accepted only
when they have no effect. This is a documented schema subset, not full profile-schema parity.

Absent file uses detected shells in memory; list/reload never writes or auto-repairs the file.
Startup with an unreadable/malformed existing file logs the error and uses detected shells;
explicit reload refuses and keeps the last good snapshot. Publish a fully validated catalog at
once. Existing sessions keep their resolved launch spec across reload, duplicate/reopen/restore.
Explicit unknown/empty profile refuses before creating any session or workspace. Command+profile
refuses as ambiguous; cwd overrides profile cwd when supplied. Default profile applies to implicit
fresh shells. Explicit args remain exact; no truncation to wire limits or cwd fallback for catalog
entries. Control-character argv refuses because existing S/P state cannot preserve it. Empty argv
retains PowerShell prompt integration; nonempty arrays are passed unchanged. Startup refusal occurs
before any window/session creation.

## Captured replay

Use the existing one-shot stable-pane-ID replay queue and current-state lookup at dispatch.
Default-off preserves current behavior and never changes user settings during implementation.
With opt-in, B > R > K; cleared/disabled K, replaced/closed/exited/read-only/adopted panes skip.
Capture's `replayOnRestore` reports the current opt-in policy, not a guarantee any command ran.
Never log command contents or enable the setting on the user's real instance. Tests inject only
harmless marker commands into isolated K slots. Cover default off, on, precedence, cancellation,
split roles, adoption, exit, readonly and exact state round-trip. K captures containing tabs/newlines
save as K2 records using the strict lossless R/B field codec. Legacy K remains readable; ordinary
captures still save as K. Older builds ignore K2, which is an explicit rollback limitation.

## OMP

Discover installed `.omp.json` files with deterministic case-insensitive names and first-directory
priority. Name or explicit existing local path resolves without running content. Reject newline/NUL
in inputs; quote paths as PowerShell literals. No network or theme execution during list/validation.
Live initialization requires an exact PowerShell executable identity, a live writable pane, and a
known shell-ready state; do not type into a running child or an unfinished draft. The post-P17
implementation uses stock PSReadLine 2.2.6–2.x in PowerShell 7 to confirm an empty buffer on idle,
then claims a bounded, one-use authorization. Completed input and completed switches are allowed;
adopted and unsupported readers refuse. Configuring future shells remains available.
Success means the native initializer and generated code completed, not merely that input was written.
An overdue claimed request is unknown and must not be automatically replayed; late native output
is not evaluated. Persist only on timely success with unchanged pane policy and saved configuration;
report partial application if persistence fails. Persisted theme applies only to eligible fresh
implicit PowerShell prompt setup, not adopted shells or explicit arbitrary profile args.

## Gates

Pure parser/catalog/replay/quoting tests; guarded live integration with redirected app data, exact
clipboard/registry ownership and canonical suite token; local build; full Strict suite on disposable
CI only. One full Codex-only review, batch substantive fixes, one focused confirmation if needed.
No cosmetic loops. Do not merge on a failing check or change canonical contract on just one side.
