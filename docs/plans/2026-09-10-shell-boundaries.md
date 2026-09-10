# Shell boundary stabilization (#41, #61)

- `PSConsoleHostReadLine` captures the incoming `$?` before bridge work and restores it at the
  saved reader boundary. `$LASTEXITCODE`, draft text and reader arguments remain unchanged.
  Resume offers are returned, never executed by this wrapper.
- Overlay commands are UTF-8/base64 data decoded once into a child script scope. Parent profile
  functions remain available; ordinary `$e`, `$b`, `$q` and `$c` assignments cannot corrupt the
  parent's OSC 133 delimiters. Status is captured immediately after the command inside its scope
  (PowerShell 5.1 does not reliably propagate a non-terminating error through `&` as `$?`).
  Wrapper bookkeeping uses reserved `__aglt133_*` names, not ordinary profile variables (including
  PowerShell `AllScope` variables). Explicit mutation of those internal names is outside this boundary.
- Standalone parsing occurs before instrumentation; parse and terminating errors retain their
  error-stream diagnostic and emit `D;1`. A normal early `return` derives status from the invocation
  when the inner status trailer was skipped. Native exit codes are retained. A trailing comment
  cannot eat the status capture. Two newline boundaries prevent a trailing continuation backtick
  from consuming the instrumentation: standalone PowerShell accepts that trailing backtick, so
  it remains valid and its output is preserved, rather than being mislabeled a parse error.
  Explicit shell exit/early closure can still bypass the trailer.
  Deliberate parent/global mutation or forged OSC remains outside this accidental-collision fix:
  the status is an in-band command claim, not a security boundary or host execution receipt.
- Encoding expansion is checked against the actual protobuf argument capacity before creation,
  popup replacement, or queued-open acknowledgement. Oversized commands refuse without truncation.
- Private unit fixtures compile the production wrapper and exercise Windows PowerShell 5.1 and
  PowerShell 7: collisions, quoted text, trailing comment, malformed syntax, terminating and
  non-terminating errors, native exit and success. Readline tests cover success/failure status
  with and without resume, using a saved custom reader. They do not claim interactive predictor UI
  coverage and never load or write the user's profile.
- CI control-path checks prove oversized popup/pane refusal before acknowledgement or session
  creation, existing popup/other-slot survival, and the established usage-refusal precedence.
- Full legacy integration remains CI-only until the outstanding shared-resource guard port (#51).
