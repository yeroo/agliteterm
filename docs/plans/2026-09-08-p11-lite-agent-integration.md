# P11-lite — commands, installers and agent integration

Boris authorized the whole P11 on 2026-09-08, including internal sub-batches without further
approval. Codex owns `agliteterm-p11` and `agwinterm-p11-status`, based on merged P10b
174b3b1 / d93fe9b. Deliver implementation and parity docs, not a release/tag. Claude is unavailable;
use only Codex reviewers. Preserve his worktrees, settings and parked process.

## Delivery scope

- `command.list/run/leader`: keymap.conf custom commands, four run modes (send/new/overlay/detached),
  exact case-insensitive labels, AGW context tokens/environment, actual key bindings and leader
  begin/state/cancel/key operations. Raw commands default to new. Readonly must reject send;
  stable target identity, modal refusal and honest write/launch acknowledgements are required.
- `install.cli/hooks/shell`: explicit opt-in only. Preserve unrelated PATH entries, profile text,
  settings and hooks. Idempotent product-owned blocks, malformed/corrupted input refusal, atomic
  replacement with recoverable backups. Codex TOML is never rewritten: supply the notify line.
  Tests use redirected files and private registry roots, never the real user profile or PATH.
- `app.update`: expose the existing channel-gated verified updater; reject developer/portable
  copies and busy/failed launch honestly. Tests cannot apply a release to the installed app.
- `claude.adopt/yolo/update`: bind exact conversations with per-pane/process evidence, never a
  guessed newest same-folder conversation. Explicit YOLO operation only; no permission change
  during installation/adoption. Restart only verified Claude descendants after proven exit;
  unknown/timeout means no relaunch. Update in a visible owned overlay; failed/no-op update must
  not restart sessions. Preserve existing command bindings and distinguish queued from completed.

## Implementation and acceptance

Use pure helpers for parsing, context expansion, profile edits, identity and restart decisions;
native UI dispatch for window/overlay creation, no global session lock across blocking I/O. Respect the
existing host transport limits; no silently dropped arguments or environment. Canonical source:
agwinterm Keymap/Program.Input, installer classes, Program.Sessions and ISessionHost.

Test all modes and leader transitions, invalid/missing fields, readonly/closed/overlay targets,
token expansion, installer preservation/idempotence/refusals, exact adoption identities and
restart cancellation/failure/no-op. Any compatibility difference must be explicit in parity docs.
Fake commands/transcripts/update tools only; never invoke the real Claude CLI during this work.

Local build and pure tests; guarded integration with acquired canonical suite token, exact owned
process teardown and clipboard/registry restoration before release. Full run-all -Strict only on
disposable Windows CI (#51). One full Codex-only revmux review, batch actionable fixes, one narrow
confirmation; more rounds only for substantive safety/correctness/acceptance blockers, not polish.
Merge only after exact-head CI and review gates, implementation before companion docs.

Implementation refinement: resume is claimed and executed by a capability-checked PowerShell prompt
bridge, not typed into PSReadLine. A per-pane input lease covers the interrupt/exit interval. Existing
or explicit-argv shells without that bridge refuse until it is explicitly loaded; default PowerShell
launches source the bundled per-process helper without modifying a user profile. This makes draft
preservation independent of user key bindings and removes the need to guess prompt input emptiness.
