# OMP live switching safety (#58)

Work in progress. The existing pristine/non-adopted guard remains enforced until the protocol below
is implemented, tested and reviewed. Discovery diagnostics are a separate contained fix.

## Shell-side direction

- Do not type initialization or a trigger key into the pane. Rendered FTCS marks cannot prove that
  PSReadLine's editing buffer is empty, and custom key handlers may run child processes inside a reader.
- Investigate an opt-in `PowerShell.OnIdle` subscriber installed by the per-process prompt asset,
  never by modifying a user's profile. PSReadLine processes script subscribers in its current-runspace
  idle path. OnIdle timing alone is not permission: require an active supported PSReadLine reader,
  a fresh direct GetBufferState empty-buffer check, and only the owning shell attached to its console.
- Apply a pending, exact nonce-bound theme request through that handler's runspace, not via terminal
  input. Queued concurrent keystrokes remain queued; never AcceptLine, RevertLine, Insert, or discard a draft.
- Reuse the authenticated shell/console identity boundary in agent.bridge, with separate OMP operation
  state. Do not reuse restart/resume leases or acknowledge more than one application of a request.
- Define deadline/claim/apply/result states before implementation. A lost result after a claim is
  unknown, not unapplied; never retry automatically or persist on mere delivery. Close/read-only,
  adoption, unsupported custom readers and late messages must have explicit safe transitions.
- Initialization success must be observed before optional persistence. Do not install/upgrade OMP
  or PSReadLine to make this work; unsupported integration keeps the conservative refusal.

## Required evidence

- Single-line draft ending in a separator, completed input, adoption, concurrent input and child
  attachment; unsupported shells/readers/PSReadLine versions; duplicate/late/missing acknowledgements.
- No initialization enters terminal input; no user draft/profile alteration; native exit/error status
  preserved around the handler. Exact theme application and persistence outcomes are asserted separately.
- Pure protocol/handler tests first; actual shell tests use the canonical token and owned job, with
  private profile/registry paths and no foreground or clipboard access.

## Primary references

- [PSReadLine idle event implementation](https://github.com/PowerShell/PSReadLine/blob/master/PSReadLine/ReadLine.cs)
- [PSReadLine function documentation and OnIdle behavior](https://github.com/MicrosoftDocs/PowerShell-Docs/blob/main/reference/7.6/PSReadLine/About/about_PSReadLine_Functions.md)

These references motivate the direction, not a claim that every installed PSReadLine version or
custom reader has the required behavior. Recheck supported implementation paths before enabling it.
