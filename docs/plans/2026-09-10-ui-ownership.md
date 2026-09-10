# UI ownership and stable sidebar targets

Closes the shared-state races tracked by #21 and #43, and the remaining active-workspace race in #36.

- Structural session/workspace control verbs, sidebar/font actions, selection mutations and tree
  snapshots execute through the existing owned UI request queue. A waiting worker holds no g_lock.
- Emulator-only reads/writes and potentially blocking shell input remain on pipe workers, with
  narrow g_lock snapshots and the existing per-pane input reservation. Host I/O is not placed
  under a dispatcher-wide lock. UI actions can still wait for bounded host operations.
- Pending requests withdrawn on timeout cannot execute later. A request that already started
  reports an unknown outcome; callers must read back before retrying. Modal editing refuses
  structural mutations, while tree snapshots remain readable.
- Sidebar rows carry a retained Session* or stable workspace token, never a vector index. Menu
  and drag actions re-resolve that identity after nested message processing. Removed targets do
  not rebind to the row or workspace now occupying their old index.
- Session objects already remain allocated after unlisting; this change does not add a new object
  reclamation scheme. Delayed row references are membership-checked before use.
- Active/focused workspace scalars are atomic for background snapshots. Split identity and
  unread bookkeeping updates use the same state lock as background readers.

Verification: private routing/actual tree-identity extraction tests, native build, Codex-only review,
then the owned-isolation runner and exact-head Windows integration CI. No clipboard or foreground
suite is run on the personal desktop. #36's other items were addressed in earlier controls work.
