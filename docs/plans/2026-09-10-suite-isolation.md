# Remaining legacy suite isolation (#51)

Plan in progress; not a local-run authorization or a completed safety claim.

- A run owns one randomly generated 32-lowercase-hex registry namespace. The application resolves
  current settings, legacy migration input and instance registrations below that namespace before
  any preference IO. Malformed explicit isolation refuses startup; no fallback into personal keys.
  With no test environment variable, ordinary application behavior is unchanged.
- Test registry adapters use the same namespace. Known assertions and implicit writes (including
  startup obsolete-key deletion and shutdown geometry) therefore leave personal value kinds and
  absent values untouched. Do not seed expected values by reading unproven personal mutations.
- The top runner acquires the canonical desktop token before launching, records its receipt,
  uses private app-data, and starts every legacy suite in a suspended-then-assigned owned job.
  The child independently attempts process, registry and clipboard teardown. The supervisor then
  proves zero owned descendants before deleting its private registry namespace or releasing the
  lease. Unknown child cleanup, timeout, job failure or registry uncertainty retains the lease and
  stops further children. An ordinary assertion failure with proven cleanup may release normally.
- Clipboard still needs full-format snapshot-before-probe and individual copy receipts. A private
  registry namespace does not isolate the clipboard, foreground, mouse capture or shared host.
  The same validated run ID selects a private host pipe, so user windows cannot join its host
  while job containment is active. Ordinary window-control names retain their existing semantics.
  Their underlying pipe endpoints receive the run prefix; the test-only forwarding adapter sends
  the unchanged verb to the real CLI with that endpoint. Raw JSON fixtures use the same mapping.
- Standalone unsafe legacy entry points must refuse without the supervisor's validated environment;
  guarded selection entry points retain their existing standalone token/restore behavior.
- `clipboard`, `control-honesty`, `conformance` and unfiltered `selection-ui` exercise paste or foreground
  transfer. They remain disposable-GitHub-CI-only even with a lease. The aggregate runner refuses
  these locally before acquiring or mutating; use explicit safe subsets for local evidence.
  This is a deliberate safety boundary, not permission to omit the full `-Strict` CI merge gate.
  The same gate covers direct `selection-ui -DrivingOnly` (empty-clipboard fallback) and
  `-RemainderOnly` (dashboard paste interception); other explicit selection filters keep their
  guarded local token behavior. If a regression bypasses an expected paste refusal, a shared
  desktop's newer clipboard text must not become the acceptance sink's input.
- The forwarding adapter has private argv/UTF-8 stdin/stdout/stderr/exit-code regression checks.
  Owned-job tests cover refusal to adopt an existing job, failed startup, repeated start refusal,
  and a live descendant after the primary exits. Mocked supervisor tests execute the real
  scheduling/finally logic with substituted resource boundaries, including receipt failure and
  unknown registry ownership; they never acquire the real token or access real HKCU.
- Fault tests, read-only Codex review, isolated CI and then token-held owned live proof gate completion.
