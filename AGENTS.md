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
5. Focused pane: Ghostty launches `HerdrTerm --bridge --target <pane> …`, which speaks NDJSON `terminal.frame` / `terminal.input` / `terminal.resize` / `terminal.scroll` / `terminal.release`
6. Scroll wheel: the GUI writes `terminal.scroll` to a per-pane FIFO (`PaneControlChannel`, path passed as `--control-pipe`) that the bridge forwards

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
- **libghostty ignores a surface's `command` and `env_vars`.** `ghostty_surface_config_s` has both fields, GhosttyKit fills them in, and libghostty drops them: the surface runs the login shell instead, so the pane showed a fresh local zsh and no bridge ever started — which reads as "my herdr session was not restored" *and* as "scrolling is broken", because the wheel handler is redirected to a FIFO nothing is reading. It is not an ABI mismatch (`working_directory`, the field before `command` in the same struct, is honoured, and the pointer is non-null at the `ghostty_surface_new` call) and not version specific (0.8.0's libghostty and a rebuild from ghostty `54ac5fd21` both drop it). The app-level config *is* honoured, so `GhosttyRuntime.useSurfaceCommand` clones the config GhosttyKit loaded, appends `command = shell:…`, and pushes it with `ghostty_app_update_config` before the surface exists. Everything the bridge needs therefore travels in that command line (`BridgeOptions.argv`), never in the surface environment.
- **A surface can fail to be created, and it says so by being null.** `ghostty_surface_new` returns null when the view has no screen — libghostty builds a `CVDisplayLink` from it, and `CVDisplayLinkCreateWithCGDisplays error -6661 ... display count (0)` surfaces as `error.OutOfMemory` in libghostty's log. A locked screen is enough to trigger it. So attach the view to the window *before* `session.attach`, and check `session.surface` afterwards: an unchecked nil renders as a working-but-empty terminal.
- **Scrolling cannot ride the PTY.** Everything the surface writes to the bridge's stdin becomes `terminal.input`, i.e. keystrokes for the program in the pane, and libghostty's own scrollback is empty because it only ever sees full viewport frames. Herdr owns the history and moves it only for `{"type":"terminal.scroll","direction":"up"|"down","lines":>0,"source":"wheel"|"page_key"}` — hence the FIFO side channel, and hence `TerminalPaneView` replacing the view's `scrollWheel` handler instead of letting libghostty handle the wheel. Both ends open the FIFO `O_RDWR` so an idle peer never reads as EOF. `controlChannelFramesScrollCommandsAsNDJSON` covers the framing; `lines: 0` and a bad `direction` make Herdr drop the command.
- **The bridge must put its PTY into raw mode.** libghostty hands the child a cooked terminal: `icanon` holds keystrokes until Enter (a TUI in the pane never sees an arrow key, or anything else, until you hit return), `echo` paints them locally over Herdr's frames, `isig` turns ^C into a signal that kills the bridge — its `herdr terminal session control` child then dies writing frames and prints `BrokenPipe` into the pane — and `ixon` eats ^S/^Q. `ControlBridge.enterRawMode()` does this before spawning herdr and restores the old settings afterwards. `stty -f /dev/ttysNN -a` on the bridge's tty must show `-icanon -isig -echo`.
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
- Nothing inside the sidebar may have an opinion about its width. A subview pinned to both edges hugs at 250, which ties with `NSSplitViewItem.holdingPriority`, and the divider then silently refuses to drag at all — that is how `emptyLabel` froze the sidebar at `minimumThickness`. Give any such view hugging and compression resistance of 1.
- `NSSplitViewController` ignores `splitView.autosaveName`: on launch it lays the sidebar out at AppKit's default thickness and autosaves *that* over the width the user dragged to. `SidebarSplitViewController` persists the width itself, and both halves are load-bearing — it restores only once the window has a frame wide enough to honour the stored width (the first layout pass runs narrower than the restored frame and would clamp it to `minimumThickness`), and it saves only when the mouse is down with the pointer on the divider, because `didResizeSubviewsNotification` also fires for a window resize that squeezes the sidebar.
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

A pane showing a local shell prompt (rather than the remote pane's content)
means the bridge never started. `pgrep -f 'HerdrTerm --bridge'` is empty and the
app has a `/usr/bin/login … /bin/zsh` child instead; libghostty's own log
(`log show --predicate 'subsystem BEGINSWITH "com.mitchellh"'`) shows
`config: default shell source=env`.

A pane that visibly reloads on a timer means the session is reconnecting, not
that rendering is slow. Distinguish the two:

- `~/.config/herdr/herdr-server.log` — repeated `terminal attach client connected` means the pane is being respawned.
- `pgrep -f 'terminal session control'` sampled once a second — a changing PID confirms it.
- The sidebar not reacting to `herdr workspace create` within ~2 s means events are not arriving.
