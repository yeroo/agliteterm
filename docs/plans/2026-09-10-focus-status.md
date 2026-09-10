# Focused pane status publication (#39)

Runtime focus-variable assignments use locked setters; owner replacement behind an unchanged
pane index may instead publish through the existing tree-refresh path. Keyboard, mouse, control commands, session changes,
split promotion and popup dismissal therefore refresh the size/read-only/search label together.
The setter message is posted, never synchronously sent while holding the session lock. Even assigning
the same pane index posts an update: its owning session and grid may have changed. An unchanged
popup override avoids redundant updates on each typed key.

Focused session/shell resolution also takes the session lock before indexing the vector. This
does not claim to complete the broader shared-state and stale sidebar-index work (#21/#43).

The extracted production setter test checks locking, notifications, same-index transitions,
popup entry/exit and no-window initialization, plus all assignment sites. Guarded driving tests
compare unequal horizontal pane labels across keyboard/mouse focus and quick-terminal dismissal.
Legacy suites remain CI-only until #51; no private check touches the user's desktop state.
