# Shell Host — Follow-up TODO

This file tracks the remaining work for the restart-tolerant shell host
(`MusterShellHost` + `ShellHostClient` + `AttentionStore`) before it's
production-ready. The initial implementation lands in this branch
(`dts/bg-shells`) but a deep multi-agent review surfaced real correctness
bugs and one architectural simplification worth making before broader use.

The original design plan lives at
`~/.claude/plans/bubbly-doodling-crystal.md` (outside the repo). This file
is the actionable follow-up.

## Current state (UPDATED 2026-04-28)

All P0, P1, P2, P3 items complete. See commits:
- `44bc1fe` - Main refactor (P0 bugs, P1 simplification, P2 dead code, P3 fixes)
- `1534a14` - Extended OSC support (9;N variants, OSC 99)

Key changes:
- Helper is now a dumb byte pipe (only output + exit events)
- Attention parsing moved to client via SwiftTerm delegates + OSCScanner
- `forkpty` replaced with `posix_spawn` for safety
- Protocol version bumped to 2
- ~250 lines deleted from duplicate parsing

## P0 — Correctness bugs ✅ COMPLETE

1. ✅ **CheckedContinuation overwrite** — Resume existing continuations
   with error before overwriting `pendingAttach`/`pendingHello`.

2. ✅ **AsyncStream continuation leak** — Finish prior `outputContinuation`
   before replacing in `sessions[checkoutId]`.

3. ✅ **fd recycle on writeQueue** — Close fd via barrier block on writeQueue
   so pending writes drain first. Fixed in both `Connection.swift` and
   `ClientConnection.swift`.

4. ✅ **fd recycle on session write** — Gate `Session.write()` on
   `exitedCode == nil`.

5. ✅ **kill() stale pid** — Dispatch SIGKILL on `session.queue` and only
   if `exitedCode` still nil.

6. ✅ **handleChildExit idempotence** — Added `didExit` flag, check
   `waitpid` return value equals `pty.pid`.

7. ✅ **forkpty Swift runtime hazard** — Replaced with `posix_spawn` +
   `openpty` + file actions for stdin/stdout/stderr.

8. ✅ **accept/quit race** — Do accept-and-register on `connQueue` under
   `quitRequested` check.

## P1 — Architectural simplification ✅ COMPLETE

✅ Deleted `AttentionParser.swift` and helper-side event pipeline.
✅ Wire SwiftTerm delegates (`bell`, `setTerminalTitle`,
   `hostCurrentDirectoryUpdate`) directly to `AttentionStore`.
✅ Added `OSCScanner` on client for OSC 9/9;N/99/777/133 sequences
   not exposed by SwiftTerm delegates.
✅ Helper is now a dumb byte pipe (output + exit events only).

## P2 — Dead code deletion ✅ COMPLETE

✅ Deleted `Drain` message type and pipeline
✅ Deleted `List` / `SessionsList` / `SessionInfo`
✅ Deleted `SetFocused` pipeline
✅ Deleted `MarkRead` pipeline
✅ Deleted `BuildStamp.helperBuildId` validation
✅ Removed redundant `public init(...)` boilerplate

## P3 — Smaller fixes ✅ COMPLETE

✅ **signal(SIG_IGN) ordering** — Set before creating dispatch sources
✅ **FrameReader quadratic copy** — Use read-head index, compact occasionally
✅ **AsyncStream memory ceiling** — Changed to `.bufferingNewest(10_000)`
✅ **Connection capture consistency** — Standardized on `[weak session]`
✅ **AttentionParser COW thrash** — Moot (parser deleted)

Note: P3 item "pump task @MainActor" was addressed differently — the pump
task is now `@MainActor`-annotated via the `Task { @MainActor [weak self] in`
pattern.

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
