# Configuration (P10a)

Run `test/selection-ui.ps1 -Strict -ConfigurationOnly -TokenOwner <actual-agent>` locally.
`-ConfigurationOnly` and `-DrivingOnly` are mutually exclusive; conflicting filters refuse before launch.
The complete selection-ui invocation also includes these cases after P7/P9. The outer fixture
acquires the canonical shared token and retains it through proven process/registry/clipboard cleanup.
Do not substitute the legacy full-suite clipboard fixture on a shared desktop (lite #51).

Acceptance: each supported config key validates, changes the live value, writes its exact registry
value and survives restart; invalid inputs refuse without mutation; unrelated registry sentinel
survives; theme modes visibly update chrome; scrollback zero/small caps affect only new replicas;
copy-on-select controls automatic clipboard writes while explicit copy remains available; keymap
reload drops stale assignments and honors deleted/default/explicit-zero states; modal Properties
allows reads but refuses mutation and duplicate opens.

All GUI input is window-scoped to the owned fixture; captures use PrintWindow. Settings opened
through the API do not raise the parent on close. No real agent commands are replayed.
P10b font/profile/OMP/captured-replay behavior is not an acceptance claim for this batch.
