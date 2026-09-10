# P10b shell configuration acceptance

Run test/selection-ui.ps1 -Strict -ShellConfigurationOnly -TokenOwner ACTUAL_OWNER under the shared
suite token. The combined entry point runs these cases after selection, driving and P10a config.
Conflicting filters refuse before creating artifacts or acquiring the token.

The fixture redirects LocalAppData, owns all windows/hosts, captures exact touched registry values,
seeds RestoreCommands off and removes OmpTheme before launch, and restores both through the existing
receipt guards. It never enables captured replay in the real user's app. All K/B/R commands are
harmless file markers created by this fixture. The fake OMP is a function inside an owned NoProfile
PowerShell, installed via explicit startup argv rather than typing into its prompt. It is not an
installed tool or user theme. OmpTheme is cleared before any restart. That unsupported reader must
refuse live OMP. The separate token-guarded `test/omp-idle.ps1` uses real stock PSReadLine in an
owned NoProfile PowerShell 7 and a private native fake tool. It covers repeat switching after completed
input, draft refusal without submission, native failure, late output not being evaluated, readonly
policy transitions and competing-window persistence. Success confirms completed initialization;
missing timely results are unknown outcomes, never a reason to replay automatically.

Required coverage: catalog reload/list/read-only file preservation; malformed/unreadable reload
retains snapshot; exact/missing/ambiguous profile refusal before workspace mutation; selected/default
shell, argv and cwd; OMP discovery, exact quoting, refusal and persistence outcome wording; replay
opt-in and B>R>K precedence; opt-out/readonly/closed/adopted/exited exclusions; split-role replay;
malformed legacy K owner refusal; legacy empty-app launch preservation; capture policy readback;
lossless K2 save/load. Record pass counts and cleanup/token evidence in the PR, not as guessed results.

Font targeting is not covered. Preserve Boris's no-zoom rule unless he changes it. Profile custom
environment, icons and elevation are explicitly unsupported, not silently accepted parity claims.
