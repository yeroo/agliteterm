# OMP live switching safety (#58)

Implemented for PowerShell 7 with the stock PSReadLine reader, versions 2.2.6 through 2.x.
Unsupported versions, custom readers and adopted panes refuse live switching; future-shell
configuration remains available. Discovery refuses incomplete enumeration instead of reporting
a partial list or resolving a lower-priority theme after an unreadable directory.

## Shell-side direction

- Do not type initialization or a trigger key into the pane. Rendered FTCS marks cannot prove that
  PSReadLine's editing buffer is empty, and custom key handlers may run child processes inside a reader.
- Use a `PowerShell.OnIdle` subscriber installed by the per-process prompt asset,
  never by modifying a user's profile. PSReadLine processes script subscribers in its current-runspace
  idle path. OnIdle timing alone is not permission: require an active supported PSReadLine reader,
  a fresh direct GetBufferState empty-buffer check, and only the owning shell attached to its console.
- Apply a pending, exact nonce-bound theme request through that handler's runspace, not via terminal
  input. Queued concurrent keystrokes remain queued; never AcceptLine, RevertLine, Insert, or discard a draft.
- Reuse the authenticated shell/console identity boundary in agent.bridge, with separate OMP operation
  state. Do not reuse restart/resume leases or acknowledge more than one application of a request.
- Keep separate queued/claimed/applied/failed/expired/unknown states. A lost result after a claim is
  unknown, not unapplied; never retry automatically or persist on mere delivery. Close/read-only,
  adoption, unsupported custom readers and late messages must have explicit safe transitions.
- Initialization success must be observed before optional persistence. Do not install/upgrade OMP
  or PSReadLine to make this work; unsupported integration keeps the conservative refusal.

## Deadlines and outcomes

- A UI-owned queue operation pins the shell PID/birth time, bridge token, request nonce and current
  configuration generation. A pipe worker waits without holding the global lock or the UI thread.
- The shell claims once after checking its actual editing buffer and sole console membership; the
  app also refuses a live direct child. Native OMP runs as an application, using the first PATH match.
- The four-second deadline uses the shared monotonic boot clock. Expiry before a claim is definitively
  unapplied. Expiry after a claim is unknown; never replay automatically. The native initializer is
  not forcibly terminated: a hung external tool can delay its reader. If it eventually returns after
  expiry, its generated script is not evaluated. An initializer already being evaluated may have
  partial side effects, including after close/read-only changes; this is trusted shell code, not a sandbox.
- Only native exit zero permits evaluating generated code. Success is acknowledged after evaluation
  and prompt rewrapping; optional persistence also requires a timely result, unchanged pane policy
  and unchanged configuration generation. Late results never persist; duplicates never apply twice.
- The handler preserves native exit status and existing error records. It never accepts, clears or
  rewrites PSReadLine input. Concurrent keystrokes remain queued until the idle callback returns.

## Evidence

- `omp-protocol.unit`: 86 state-transition checks, including ineligible/duplicate/late/missing results.
- `omp-shell.unit`: 84 actual-handler checks with a native fake tool, including exact quoted path,
  native failure, evaluation error, drafts, expiry, duplicate execution, unchanged/replaced prompts,
  multiple PATH matches, native exit status and error-record identity.
- `omp-idle`: real PSReadLine with a private native fake OMP, exact theme and persistence readback,
  completed prior input, a single-line separator draft and a barrier-controlled concurrent draft.
  Native failure must neither evaluate its output nor replace the persisted theme. Read-only refuses.
- Actual shell tests run through the canonical token/owned-job supervisor with private profile,
  history and registry paths, no foreground or clipboard access. They do not execute installed OMP
  or modify a user profile. Unsupported PS5/custom-reader refusal is also covered in selection-ui.
- Review and exact-head CI are still required before merging; these are implementation evidence,
  not a claim of testing every third-party prompt customization or OMP release.

## Primary references

- [PSReadLine idle event implementation](https://github.com/PowerShell/PSReadLine/blob/master/PSReadLine/ReadLine.cs)
- [PSReadLine function documentation and OnIdle behavior](https://github.com/MicrosoftDocs/PowerShell-Docs/blob/main/reference/7.6/PSReadLine/About/about_PSReadLine_Functions.md)

These references describe the idle contract, not a claim that every installed PSReadLine version or
custom reader has the required behavior. Keep the supported-reader/version gate when extending it.
