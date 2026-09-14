# User guide

## The window

agliteterm uses real native controls — menu bar, toolbar, TreeView sidebar, status bar — in the
classic Windows look.

- **Themes**: Dark / Light / Classic / Auto (follows Windows) from *File ▸ Properties*. Dark covers
  everything — menus, toolbar, sidebar, dialogs, scrollbars, title bar. **Classic** keeps the
  authentic raised-3D, pre-theme look.
- **Fonts**: a font catalog including bundled Cozette, Tamzen, Terminus, Spleen, UNSCII and GNU
  Unifont bitmap fonts. Face and size are chosen once in Properties; there is deliberately **no
  zoom**, because a raster face only exists at the strike sizes its pack ships. An MS-DOS/EGA palette
  and a cmd.exe-style Properties dialog are there too.
- **Sidebar text size** is set separately (*Properties ▸ Sidebar text*), because wanting a bigger
  session list is not wanting a bigger terminal.

## Agent workflow

- Per-session **agent status**: bold = blocked, italic = working.
- An **attention bell** that lights amber and jumps to the next blocked session.
- **Flagged sessions** with a flagged-only view.
- **Unread badges**: commands that finished while a session was off-screen.
- Workspace focus and sidebar **drag & drop**.
- **Workspace attention**: opt-in keyboard broadcast, clickable notifications, fixed-strike live
  dashboard previews, workspace reordering and explicit saved-state clearing. See
  [behavior and safety boundaries](workspace-attention.md).

## Sessions, splits and popups

- Workspaces and sessions, restored on the next launch ([session restore](session-restore.md)).
- A 2-pane split (left/right or top/bottom), either side closable, the two swappable.
- Quick, scratch and overlay popup terminals.
- A **pane overlay**: a command drawn over ONE pane's box, badged `overlay`, while the other pane
  stays interactive (`session overlay open <cmd> --pane left|right`).
- **Multi-window**: every window is its own tiny process (`--pipe <name>`), all sharing one pty-host.

## Keys

Keys are fully rebindable. Ctrl+Shift+P opens the palette, Ctrl+Shift+M toggles mark mode,
Ctrl+Shift+A selects all; other actions start unbound.

The two pane-focus rows are by **slot**: *Focus Left / Top Pane* is slot 0 and *Focus Right / Bottom
Pane* slot 1, whichever shell a `session swap` put there, and the same two rows serve both axes.

Custom commands, leader chords and the keymap file are in
[commands and agent integration](agent-integration.md).

## Clipboard

- Select with the mouse and it is copied on release. Double- and triple-click select a word and a
  line; dragging past an edge auto-scrolls.
- Mark mode starts at the caret: arrows and Home/End extend, Enter or Ctrl+C copies and exits while
  keeping the highlight, Esc or the configured mark chord clears and exits. Select All only
  highlights.
- These work in panes and in overlay, quick and scratch popups. The alt screen stays pinned to its
  own rows: wheel, drag and mark mode cannot reach main-screen history.
- **Ctrl+C copies a selection** and otherwise interrupts the shell (Ctrl+Shift+C always copies).
- **Right-click pastes**, even while a full-screen app is grabbing the mouse. A TUI like Claude Code
  holds mouse mode on for its whole run, which is exactly when pasting matters.
- A program can drive the clipboard itself with **OSC 52**, and terminal queries get answered.
- Both bindings are on by default; the registry escape hatch is `RightClickPaste` / `CopyOnCtrlC`
  (DWORD `0`) under `HKCU\Software\agliteterm`. See [configuration](configuration.md).

## Command line

`-p/--profile`, `-d/--dir`, `--maximized`, `--no-restore`, `--pipe` — the full app's flag names —
plus `--diagnose` ([troubleshooting](troubleshooting.md)).
