# Shell Host — Follow-up TODO

This file tracks the remaining work for the restart-tolerant shell host
(`MusterShellHost` + `ShellHostClient` + `AttentionStore`) before it's
production-ready. The initial implementation lands in this branch
(`dts/bg-shells`) but a deep multi-agent review surfaced real correctness
bugs and one architectural simplification worth making before broader use.

The original design plan lives at
`~/.claude/plans/bubbly-doodling-crystal.md` (outside the repo). This file
is the actionable follow-up.

## Current state

- All ten implementation tasks complete; app builds; integration tests
  pass (`testRoundtrip`, `testReattachPreservesSession`).
- Helper embedded at `Muster.app/Contents/MacOS/MusterShellHost`,
  detached via `posix_spawn(POSIX_SPAWN_SETSID)`, survives app quit.
- Sessions persist across app relaunch via session UUID; helper-side
  ring buffer (1 MiB) replays on reattach.
- Attention surfaces (sidebar badge, dock bounce, notifications) wired
  through `AttentionStore`.

## P0 — Correctness bugs (must fix before broader use)

These fire under normal use, not edge cases. File:line refs are exact.

1. **CheckedContinuation overwrite — process trap on second attach for
   same checkout.**
   `Sources/MusterCore/Services/ShellHostClient.swift:128` (`pendingAttach`)
   and `:310` (`pendingHello`). Reassignment drops the prior continuation
   without resuming; Swift traps on dealloc-without-resume.
   Fix: before `pendingAttach[id] = cont`, resume any existing entry with
   `ShellHostError.attachFailed("superseded")`. Same pattern for
   `pendingHello`.

2. **AsyncStream continuation leak — `RemoteTerminalView` retained
   forever on re-attach for same checkout.**
   `Sources/MusterCore/Services/ShellHostClient.swift:115`. Overwrites
   `sessions[checkoutId]` without finishing the prior `outputContinuation`.
   Old `pumpTask` hangs forever, holding the view.
   Fix: `if let prior = sessions.removeValue(forKey: checkoutId) { prior.outputContinuation.finish() }`
   before installing the new state.

3. **fd recycle / use-after-close on `Connection.writeQueue`.**
   `Sources/MusterShellHost/Connection.swift:163-181`. `close()` runs on
   `readQueue` and closes `socketFd`; queued blocks on `writeQueue` still
   capture `socketFd` by value and write to it post-close. macOS recycles
   fd numbers aggressively — pending writes hit unrelated sockets/files.
   Fix: close fd from `writeQueue` after a barrier
   (`writeQueue.async { Darwin.close(fd) }` posted from the close path)
   so all pending writes drain first. Same fix needed in
   `Sources/MusterCore/Services/ClientConnection.swift:79-91`.

4. **fd recycle on session write after child exit.**
   `Sources/MusterShellHost/Session.swift:138-154`. `Session.write` block
   enqueued from `Connection.handleFrame .input` runs on `session.queue`
   after `handleChildExit` already closed `pty.masterFd`. Same recycle
   hazard.
   Fix: gate `write()` on `exitedCode == nil` (read on `session.queue`).

5. **`Session.kill()` escalation captures stale pid.**
   `Sources/MusterShellHost/Session.swift:161-170`. SIGTERM, then 1s
   later SIGKILL fires against `pid` — but the kernel may have recycled
   that pid for an unrelated user process by then.
   Fix: in the asyncAfter, dispatch onto `session.queue` and only
   escalate if `exitedCode == nil`.

6. **`handleChildExit` interprets `waitpid==0` as exit code 0.**
   `Sources/MusterShellHost/Session.swift:82-90`. If the child was
   already reaped (e.g. by a prior fire), `waitpid(WNOHANG)` returns 0
   with `status` uninitialized; current code reads it as exit code 0.
   Fix: capture `let r = waitpid(...)` and only update state if
   `r == pty.pid`. Add a `didExit` flag for idempotence.

7. **forkpty child performs Swift Array operations between fork and
   exec.**
   `Sources/MusterShellHost/PTY.swift:52-71`. `withUnsafeBufferPointer`
   on Swift Arrays after `forkpty` can hit Swift runtime locks, causing
   deadlock if the parent had any other thread holding malloc/runtime
   state at the moment of fork (likely under Foundation + Dispatch).
   Fix: pre-build raw `UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>`
   with `calloc` *before* fork; pass plain C pointers to `execve`.
   Alternative cleaner fix: replace `forkpty` with `posix_spawn` +
   `posix_spawn_file_actions_addopen` (open the slave PTY device as
   stdin/stdout/stderr) + `POSIX_SPAWN_SETSID`. Removes the Swift
   runtime hazard entirely, drops the strdup-before-fork dance.

8. **SocketServer accept/quit race.**
   `Sources/MusterShellHost/SocketServer.swift:99-108`. Connection is
   constructed and starts reading on `acceptQueue`, but registration in
   `connRefs` is dispatched async to `connQueue`. Between the two,
   `requestQuit()` can run on `connQueue`, see an empty `connRefs`,
   leave the dispatch group, and return — orphaning the just-accepted
   Connection.
   Fix: do the entire accept-and-register sequence on `connQueue` under
   the `quitRequested` check.

## P1 — Architectural simplification (high leverage)

**Move attention parsing from helper to client; delete
`AttentionParser.swift`.**

The helper currently parses BEL / OSC 0/1/2/7/9/777/133 from the byte
stream and emits structured events. SwiftTerm *also* parses every one
of these and exposes them via `TerminalViewDelegate` (`bell`,
`setTerminalTitle`, `hostCurrentDirectoryUpdate`, `iTermContent` for
OSC 9/777). `RemoteTerminalView.swift:104-117` stubs all of those out.
We're parsing twice.

The cached `RemoteTerminalView` in `TerminalCache` stays alive across
UI dismissal, so its delegate fires regardless of whether the view is
displayed — which is exactly what we need for "background sessions
get bell badges too."

Delete:
- `Sources/MusterShellHost/AttentionParser.swift` (~110 lines)
- `BellEvent`, `NotifyEvent`, `TitleChangedEvent`, `CwdChangedEvent`,
  `PromptMarkEvent` from `Sources/MusterShellProtocol/Messages.swift`
- The corresponding `MessageType` cases in `MusterShellProtocol.swift`
- The dispatch logic in `Session.swift` (`dispatchEvents`,
  `unreadBells`, `currentTitle`, `markRead`)
- The matching branches in `ShellHostClient.handleFrame`
- `AttentionEvent.Kind` cases except `.exited`

Move attention escalation logic into `RemoteTerminalView`'s delegate
methods: forward bell/title/cwd/iTermContent to `AttentionStore.shared`,
keyed by `checkoutId`. The helper becomes a dumb byte pipe.

Net: ~250 lines deleted, one process boundary made coherent.

**Important nuance:** OSC 133 prompt marks (`commandEnd` with exit code)
require shell integration to be sourced, and SwiftTerm's `iTermContent`
delegate may or may not surface these. Verify before deleting; if
SwiftTerm doesn't expose 133, keep that one parser branch
client-side as a separate filter on the byte stream before feeding
SwiftTerm.

## P2 — Dead code deletion

These were added speculatively or for v1-only purposes that no longer
apply.

- **`Drain` message type and pipeline.** Comment in
  `Connection.swift:151` says "same as quit (proper drain semantics
  deferred)." Never sent by the client. Delete the type, the enum
  case, and the branch.
- **`List` / `SessionsList` / `SessionInfo`.** Never sent. Server-side
  `SessionManager.list()` reads `Session.exitedCode` off-queue (data
  race) — but the whole pipeline is unused. Delete.
- **`SetFocused` pipeline.** Helper stores `Connection.isFocused` but
  never reads it; client tracks focus locally in `AttentionStore`.
  Delete the message type, `SessionClient.isFocused`, the
  `setFocused` closure on `ShellSession`, and the corresponding
  branches.
- **`BuildStamp.helperBuildId` validation.** Helper and app ship in the
  same `.app` bundle — version handshake validates a tautology. Keep
  `protocolVersion` (defensive plumbing for future detached/installed
  helper); drop `buildId` and the `versionMismatch` arm.
- **Boilerplate `public init(...)` on every Codable in `Messages.swift`.**
  ~60 lines of pure assignment. Synthesized memberwise init suffices
  for the few types instantiated cross-module; drop `public` initializers
  on the rest.

Total: ~150 lines deleted.

## P3 — Smaller correctness/perf fixes

- **`signal(SIG_IGN)` ordering in `main.swift:95-108`.** Currently set
  *after* `makeSignalSource` + `resume()` — small window where SIGTERM
  triggers default disposition. Fix: ignore signal *before* creating
  the source.
- **`FrameReader` quadratic copy.** `Frame.swift:45`
  `buffer.removeSubrange(0..<n)` shifts remaining bytes on every frame.
  Becomes O(n²) under sustained high-volume output. Fix: track a
  read-head index instead of mutating the buffer; compact occasionally.
- **AsyncStream `.unbounded` for output.**
  `ShellHostClient.swift:112`. A runaway `find /` could OOM. Switch to
  `.bufferingNewest(N)` (e.g. N = 10_000 chunks) for a memory ceiling.
- **`RemoteTerminalView` pump task not `@MainActor`-annotated.**
  `Muster-macOS/Views/TerminalView.swift:65-68`. Currently hops to
  `MainActor.run` per chunk — perf cliff on high-throughput output.
  Fix: annotate the pump `Task` `@MainActor` and feed directly.
- **Connection capture inconsistency.**
  `Sources/MusterShellHost/Connection.swift:103, 121`. `.input` captures
  `session` strongly; `.detach` uses `[weak session]`. Standardise on
  `[weak session]` everywhere.
- **AttentionParser COW thrash.** `case .osc(var buf)` reconstructs the
  enum every byte (~4096 reallocations for a 4KB OSC string). Moot if
  P1 deletes the parser; otherwise move buffer to a stored property.

## Deferred — v2

Acknowledged-and-deferred items, not blocking v1.

- **PTY fd handoff via `sendmsg(SCM_RIGHTS)`** so sessions survive
  helper upgrade. Currently helper restart loses sessions.
- **Helper crash recovery / reconnect logic** in `ShellHostClient`.
  Currently `handleDisconnect` finishes all streams; no retry. v2:
  reconnect with same UUIDs, helper replays from ring buffer.
- **`SMAppService.daemon` / `.agent` for helper management.** Replaces
  `posix_spawn` + `setsid` + dup2 boilerplate with launchd-managed
  service; gives crash-restart, log rotation, single-instance
  enforcement for free. Also enables reboot survival if scope expands.
- **OSC 133 shell integration snippet** shipped with the app and
  auto-sourced via `ZDOTDIR` shim. Required for clean "command
  finished with exit code N" events.
- **Helper version-skew drain & relaunch flow.** Designed in
  `bubbly-doodling-crystal.md` but only relevant once helper is
  separately installed (e.g. via SMAppService). Not relevant while
  bundled.
- **NSXPC migration.** Architecture review's strongest suggestion;
  pushed back on for v1 because (a) we're an unsandboxed dev tool,
  not a sandbox-aware service, and (b) the custom protocol is more
  flexible for future helper-version-skew handling. Worth revisiting
  if the protocol design churns.
- **Shared `FrameSocket` extracted into `MusterShellProtocol`** to
  collapse the duplication between `Connection.swift` (helper) and
  `ClientConnection.swift` (app). ~80 lines of similar boilerplate.

## Suggested order of operations

Estimated: ~half a day for P0 + P1 + P2. Starts with P1 because it
changes the shape of things and would conflict with P0 fixes if
deferred.

1. P1: delete `AttentionParser.swift` and the helper-side event
   pipeline; wire SwiftTerm delegate methods to `AttentionStore`.
2. P0.7: replace `forkpty` with `posix_spawn` + addopen + SETSID.
3. P0.1, P0.2: continuation overwrite and AsyncStream leak fixes.
4. P0.3, P0.4: fd-recycle fixes (close-from-writeQueue + write gate).
5. P0.5, P0.6, P0.8: kill escalation, waitpid check, accept race.
6. P2: delete dead pipelines and boilerplate.
7. P3: smaller fixes.

## Files changed in this branch

New:
- `Sources/MusterShellProtocol/{MusterShellProtocol,Frame,Messages}.swift`
- `Sources/MusterShellHost/{main,PTY,RingBuffer,AttentionParser,Session,SessionManager,Connection,SocketServer}.swift`
- `Sources/MusterCore/Services/{ShellHostClient,ClientConnection}.swift`
- `Muster-macOS/Attention/AttentionStore.swift`
- `Tests/MusterShellProtocolTests/FrameTests.swift`
- `Tests/MusterCoreTests/ShellHostIntegrationTests.swift`

Modified:
- `Muster-macOS/Views/TerminalView.swift` — rewrote `TerminalCache`
  internals; new `RemoteTerminalView` wraps `SwiftTerm.TerminalView`
  base.
- `Muster-macOS/Views/TerminalContainerView.swift` — uses
  `checkout.id` not `checkout.path`; wires `AttentionStore` focus.
- `Muster-macOS/Views/SidebarView.swift` — checkout/repository
  deletion fires `TerminalCache.shared.discard(checkoutId:)`;
  `CheckoutRow` shows attention badge.
- `Package.swift`, `project.yml` — new targets, helper embedded in
  app bundle.
