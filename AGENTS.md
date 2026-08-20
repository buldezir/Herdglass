# herdr-term

Native macOS AppKit GUI client for a remote [Herdr](https://herdr.dev) server. The chrome is cmux-like (vertical workspace sidebar, attention rings, GPU terminal). Herdr stays the multiplexer; this app does not own panes, agents, or splits.

Do not fork or copy [cmux](https://github.com/manaflow-ai/cmux) (AGPL). Rendering uses [GhosttyKit](https://github.com/briannadoubt/GhosttyKit) / libghostty (MIT), pinned in `Package.swift`.

## Layout

- `Sources/HerdrClient/` — SSH attach, Unix JSON-RPC, `terminal session control` bridge, models
- `Sources/HerdrTerm/` — AppKit window, sidebar, connect sheet, Ghostty host view
- `Tests/HerdrClientTests/` — parsing, framing, and RPC-transport tests
- `Scripts/dev.sh` — build `.build/HerdrTerm.app` and optionally `--run` (extra args pass through)

Entry: `HerdrTermMain.swift`. Flags: `--bridge` (PTY child for libghostty), `--connect <host>` (skip the connect sheet), `--self-test <host>`.

## Architecture

```
GUI  --session.snapshot / events.subscribe / pane.focus-->  forwarded herdr.sock (API)
GUI  --spawns-->  HerdrTerm --bridge  --herdr terminal session control-->  forwarded herdr-client.sock
```

`herdr --remote` is TUI-only (cannot prefix CLI subcommands). Attach is our SSH ControlMaster:

1. `BatchMode` SSH (key must already be in `ssh-agent`)
2. Find remote `herdr` at Homebrew/mise/Nix/`~/.local/bin` — non-interactive PATH has no Homebrew
3. Ensure `herdr server`, parse `socket:` from `herdr status server`
4. Forward **both** `herdr.sock` (API) and `herdr-client.sock` (direct terminal attach)
5. Focused pane: Ghostty launches `HerdrTerm --bridge`, which speaks NDJSON `terminal.frame` / `terminal.input` / `terminal.resize` / `terminal.release`

`SessionController` owns connection state; `MainWindowController` turns a snapshot into a `SidebarModel` and drives `TerminalPaneView`. `StatusStyle` is the only place agent status becomes a color or a word.

v1 shows one focused pane; switch from the sidebar. Remote splits still exist on the server.

## Constraints agents should not re-break

The first four interact, and together they produced a pane that visibly reloaded
every two seconds while the window still read as "connected". Read all four
before touching `HerdrRPC` or `SessionController`.

- **The API socket is one request per connection.** Herdr answers `session.snapshot` (etc.) and immediately hangs up, so `HerdrRPC` dials a fresh socket per call. Caching it makes every request after the first throw, which the UI reads as a dropped session and reconnects. Covered by `repeatedRequestsSurviveAServerThatHangsUpEachTime`.
- **`events.subscribe` is all-or-nothing, and pane-scoped types poison it.** `pane.agent_status_changed`, `pane.scroll_changed` and `pane.output_matched` each require a `pane_id`. Including one without it makes Herdr reject the *entire* call, so the client gets no events whatsoever. Keep `HerdrRPC.eventTypes` to session-wide types only — `subscriptionListOmitsPaneScopedEvents` guards this. Check any new type against the schema first:

  ```bash
  herdr api schema --json | python3 -c "import json,sys; \
    [print(v['properties']['type']['const'], [r for r in v.get('required',[]) if r!='type']) \
     for v in json.load(sys.stdin)['schemas']['request']['\$defs']['Subscription']['oneOf']]"
  ```

- **A rejected subscription arrives as a line on the stream, not as a thrown error.** `subscribe` therefore reads the `subscription_started` acknowledgement synchronously and throws on anything else. Without that, a rejection is indistinguishable from a quiet session: the stream stays open, no event ever lands, and the poll fallback never engages. Covered by `subscribeThrowsWhenTheServerRejectsTheSubscription`.
- **Keep the poll behind the event stream.** It is not redundant: agent status is only pushed by the pane-scoped `pane.agent_status_changed`, which a session-wide client cannot subscribe to, so attention rings would otherwise depend on some other event happening to fire. `SessionController` polls every 2 s alongside events, and every 0.9 s when the server refuses to subscribe us.
- Remote scripts must go to `ssh host bash -s` on **stdin**. Extra argv after the host is joined with spaces and executed by zsh, which splits on `;`.
- `HERDR_SOCKET_PATH=.../herdr.sock` makes `herdr terminal session control` open `.../herdr-client.sock`. Forward both or control fails with "No such file or directory".
- Never `FileHandle.write` to a pipe that a child may have closed; EPIPE becomes an ObjC exception and `abort()`s. Use `writeIgnoringBrokenPipe` and keep `HerdrProcess.setUp()` (SIGPIPE ignored) on every entry point.
- Never read a subprocess pipe only after `waitUntilExit()`; that deadlocks past the ~64 KB pipe buffer. `ProcessRunner` drains both streams concurrently — see `processRunnerSurvivesOutputLargerThanThePipeBuffer`.
- `LineBuffer` yields `Data`, not `String`. A non-UTF-8 frame must not end the drain loop while complete records are still queued.
- Launch from a shell (`./Scripts/dev.sh --run` or `swift run HerdrTerm`), not `open` / Finder, or `SSH_AUTH_SOCK` is missing.
- GhosttyKit is arm64 macOS 14+ and an unstable C API — pin the package version.

## UI conventions

- No hardcoded colors. Semantic `NSColor`s and `StatusStyle` only, so light mode works; the sidebar's translucency comes from `NSSplitViewItem(sidebarWithViewController:)`.
- The content pane is pinned to `safeAreaLayoutGuide`, not raw bounds — the window uses `.fullSizeContentView` and content would otherwise sit under the toolbar.
- `SidebarView.apply` reloads only when row identity changes and reconfigures cells in place otherwise; a full `reloadData` on every snapshot would throw away scroll position and the user's collapsed workspaces.
- libghostty's tick is reference counted by attached panes (`GhosttyRuntime`), not left running at 60 Hz forever.
- Window-scoped key monitors must be removed in `windowWillClose`, or a closed window keeps swallowing ⌘1…⌘9.
- A bridge that exits on its own must **not** be re-attached automatically (`TerminalPaneView.detachedPaneId`); refresh would immediately respawn it and spin. Re-attaching is permission the user grants by picking the pane again, which routes through `MainWindowController.select`.

## Verify

```bash
swift test --filter HerdrClientTests
swift build --product HerdrTerm
# needs a running herdr server:
.build/debug/HerdrTerm --self-test local
./Scripts/dev.sh --run --connect local
```

A pane that visibly reloads on a timer means the session is reconnecting, not
that rendering is slow. Distinguish the two:

- `~/.config/herdr/herdr-server.log` — repeated `terminal attach client connected` means the pane is being respawned.
- `pgrep -f 'terminal session control'` sampled once a second — a changing PID confirms it.
- The sidebar not reacting to `herdr workspace create` within ~2 s means events are not arriving.
