# Bounded host control exchange (#27)

The client opens its control pipe overlapped. Each framed exchange has one two-second budget,
including contention with another caller, the complete write, reply header, and reply payload.
Partial reads/writes advance within that same budget; a slow drip cannot renew it. Existing
resize try-lock and bounded retry behavior remains, with no global session lock held over I/O.
This bounds the direct UI call but does not claim all host operations are asynchronous or instant.

A timeout waiting for the transport lock issues nothing and leaves the current owner alone.
Initial handle/event setup failures also preserve the untouched pipe. Failures report the operation
stage and Win32 error, distinguishing deadline expiry from broken transport or local setup failure.
An issued exchange that fails retires the pipe, so later requests cannot consume its late reply.
Cancellation never frees an outstanding OVERLAPPED, buffer, event or duplicated pipe handle:
completed cancellations are reaped on subsequent calls, while unresolved records remain owned
until process exit. Cleanup does not add an unbounded cancellation wait to the UI thread.
The transport itself intentionally has process lifetime because detached control workers can still
be using its mutex at CRT shutdown. A retired startup probe is Dead, never a usable HelloOnly fallback.

There is no automatic mutation replay or runtime reconnect. Existing data pipes can still drain;
host control becomes unavailable until the client restarts and performs its normal handshake/adoption.
The reply may have been lost after execution: failure does not prove that Create/Resize/Kill did
nothing. Safe reconciliation of lost Create replies needs the separate incarnation protocol work
tracked in full agwinterm #279. This change does not claim to solve that or Lite #21/#43 shared-state races.

Private named-pipe tests exercise complete and partial frames, stalled writes/headers/payloads,
oversized/truncated replies, total-budget drip feeding and lock contention without launching a
terminal, pty host, or touching clipboard/registry/profile state. Legacy full integration stays
CI-only until the #51 guard migration is complete.
