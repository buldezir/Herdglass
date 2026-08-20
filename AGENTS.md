# herdr-term

Native macOS AppKit GUI client for remote [Herdr](https://herdr.dev) servers. The chrome is cmux-like (sidebar, attention rings, GPU terminal) and maps 1:1 onto Herdr's own nouns: **sidebar folders are hosts, their children are spaces (Herdr workspaces), the strip above the terminal is the space's tabs, and a tab's panes are drawn as splits.** Herdr stays the multiplexer; this app owns no panes, agents, or layouts of its own — it renders what the server reports and asks the server to change it.

Do not fork or copy [cmux](https://github.com/manaflow-ai/cmux) (AGPL). Rendering uses [GhosttyKit](https://github.com/briannadoubt/GhosttyKit) / libghostty (MIT), pinned in `Package.swift`.

## Layout

- `Sources/HerdrClient/` — SSH attach, Unix JSON-RPC, `terminal session control` bridge, models, split-layout tree (`Layout.swift`)
- `Sources/HerdrTerm/` — AppKit window, sidebar (hosts → spaces), tab strip, split container, connect sheet, Ghostty host view, ghostty-config reader (`GhosttyConfig.swift`)
- `Tests/HerdrClientTests/` — parsing, framing, and RPC-transport tests
- `Scripts/dev.sh` — build `.build/HerdrTerm.app` and optionally `--run` (extra args pass through)

Entry: `HerdrTermMain.swift`. Flags: `--bridge` (PTY child for libghostty), `--connect <host>` (skip the connect sheet), `--self-test <host>`, `--show-ghostty-config` (what the app took from the user's ghostty config, and the menu it produced).

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

The app is a ghostty client as much as a Herdr one, so it reads the user's own
`ghostty` config rather than inventing settings of its own: `GhosttyConfig`
snapshots the keys that describe a *window* — colours, opacity, titlebar,
`window-theme`, `confirm-close-surface`, `focus-follows-mouse` — plus the
`keybind`s for the actions this app can perform, and `GhosttyRuntime` owns the
`ghostty_config_t` everything reads from. `--show-ghostty-config` prints the lot,
including which menu shortcuts came from the config and which are ours.

`ConnectionsController` owns the window's hosts — one `SessionController` per host, each with its own SSH master, event stream and selection (space → tab → pane). Only the selected host is `isVisible`, so only its panes have bridges. `MainWindowController` turns all of that into a `SidebarModel`, a `TabBarModel` and a `SplitContainerView.Model`; `StatusStyle` is the only place agent status becomes a color or a word.

A tab's panes are all live at once: `SplitContainerView` builds nested `NSSplitView`s from the tab's split tree, one `TerminalPaneView` (and one bridge) per pane. Dragging a divider is a `layout.set_split_ratio` on the server, so the TUI and every other client see the same geometry. ⌘D / ⇧⌘D are `pane.split`, ⌘⌥arrows are `pane.focus_direction` — the GUI never computes geometry itself.

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
- **libghostty ignores a surface's `command` and `env_vars`.** `ghostty_surface_config_s` has both fields, GhosttyKit fills them in, and libghostty drops them: the surface runs the login shell instead, so the pane showed a fresh local zsh and no bridge ever started — which reads as "my herdr session was not restored" *and* as "scrolling is broken", because the wheel handler is redirected to a FIFO nothing is reading. It is not an ABI mismatch (`working_directory`, the field before `command` in the same struct, is honoured, and the pointer is non-null at the `ghostty_surface_new` call) and not version specific (0.8.0's libghostty and a rebuild from ghostty `54ac5fd21` both drop it). The app-level config *is* honoured, so `GhosttyRuntime.useSurfaceCommand` clones the config we loaded, appends `command = shell:…`, and pushes it with `ghostty_app_update_config` before the surface exists. Everything the bridge needs therefore travels in that command line (`BridgeOptions.argv`), never in the surface environment.
- **A surface can fail to be created, and it says so by being null.** `ghostty_surface_new` returns null when the view has no screen — libghostty builds a `CVDisplayLink` from it, and `CVDisplayLinkCreateWithCGDisplays error -6661 ... display count (0)` surfaces as `error.OutOfMemory` in libghostty's log. A locked screen is enough to trigger it. So attach the view to the window *before* `session.attach`, and check `session.surface` afterwards: an unchecked nil renders as a working-but-empty terminal.
- **Scrolling cannot ride the PTY.** Everything the surface writes to the bridge's stdin becomes `terminal.input`, i.e. keystrokes for the program in the pane, and libghostty's own scrollback is empty because it only ever sees full viewport frames. Herdr owns the history and moves it only for `{"type":"terminal.scroll","direction":"up"|"down","lines":>0,"source":"wheel"|"page_key"}` — hence the FIFO side channel, and hence `TerminalPaneView` replacing the view's `scrollWheel` handler instead of letting libghostty handle the wheel. Both ends open the FIFO `O_RDWR` so an idle peer never reads as EOF. `controlChannelFramesScrollCommandsAsNDJSON` covers the framing; `lines: 0` and a bad `direction` make Herdr drop the command.
- **The bridge must put its PTY into raw mode.** libghostty hands the child a cooked terminal: `icanon` holds keystrokes until Enter (a TUI in the pane never sees an arrow key, or anything else, until you hit return), `echo` paints them locally over Herdr's frames, `isig` turns ^C into a signal that kills the bridge — its `herdr terminal session control` child then dies writing frames and prints `BrokenPipe` into the pane — and `ixon` eats ^S/^Q. `ControlBridge.enterRawMode()` does this before spawning herdr and restores the old settings afterwards. `stty -f /dev/ttysNN -a` on the bridge's tty must show `-icanon -isig -echo`.
- **An `NSSplitView` must never be its own delegate.** AppKit's `NSSplitViewSidebar` category answers `respondsToSelector:` by asking the delegate, so `delegate = self` recurses until the stack guard is hit — `EXC_BAD_ACCESS` in `objc_loadWeakRetained` under `-[NSSplitView respondsToSelector:]`, on a timer, from toolbar validation. `SplitNodeView` therefore keeps a separate `SplitNodeDelegate` (and must retain it: `delegate` is weak).
- **The split tree comes from `layout.export`, not from the snapshot.** `session.snapshot` has a `layouts` array, but it is flat — cell rectangles plus a list of splits — and reconstructing the nesting from rounded cell rects is guesswork. `layout.export` returns `first`/`second`/`direction`/`ratio` directly. It is a second round trip, so `SessionController` only asks when `LayoutSummary.signature` for the selected tab changes; polling the tree every 2 s would double the request rate for nothing. Only the selected tab is ever fetched.
- **`layout.set_split_ratio` addresses a divider by path, not by id.** `path` is one bool per descent from the tab's root split, `false` into `first` and `true` into `second`; `[]` is the root. `splitRatioPathsAreFirstFalseSecondTrue` pins the mapping, because a wrong path silently resizes a different divider.
- **A divider ratio may only be published from the drag itself.** `NSSplitView` reports every resize through `didResizeSubviews`, window resizes included — the same trap as the sidebar width. `SplitNodeView` instead reads the ratio after `super.mouseDown` returns, which is exactly the span of the divider's tracking loop, and re-applies the model ratio in `layout()` only when it differs from what was last applied (otherwise the layout pass fights the drag).
- **Rebuild the pane hierarchy on structure, not on ratios.** `LayoutNode.structureSignature` omits ratios; keying the rebuild on the full tree would tear down and respawn every bridge in the tab on each divider drag. `TerminalPaneView`s are cached by pane id and moved between hierarchies, and only a pane that left the tree is torn down.
- **The per-surface command is global, and that is still safe for several panes.** `GhosttyRuntime.useSurfaceCommand` pushes the bridge command through the *app* config before each `ghostty_surface_new`, so attaching N panes in one pass looks like a race. It is not: `ghostty_app_update_config` takes effect before the next surface is created, and a four-pane split really does produce four bridges with four distinct `--target`s (`pgrep -fl 'HerdrTerm --bridge'`). Attach panes on the main thread, one after another, and do not "optimise" this into anything concurrent.
- **`ghostty_config_get` writes through a `void*`, so the Swift type has to match the Zig field.** libghostty decides the type from the config field (`src/config/c_get.zig`): `bool`, `c_uint` for `u8`/`u32`, `c_short` for `i16`, `f64`, `ghostty_config_color_s` for a colour, and `const char*` for both strings *and* enum tags. Read a key into something smaller than it writes and you corrupt the stack, silently. It returns false — writing nothing — for a key the C API does not expose and for an optional that is unset, which is how `split-divider-color` says "derive one". Plain Zig structs with no `cval` are simply unreachable: that is why `mouse-scroll-multiplier` and `config-file` are not honoured, and why `theme` has to be spotted by reading the config text.
- **Do not load the config through GhosttyKit.** `GhosttyTerminalHost(loadDefaultTheme: true)` — which is what `GhosttyTerminalHost.shared` is — writes a Rosé Pine theme into Application Support and loads it *after* the user's config whenever no config file in the ghostty config directory has a `theme =` line. It overrides `background`, `foreground`, `palette`, `background-opacity` and `background-blur`, so an app that reads those back is reading GhosttyKit's opinion, not the user's. `GhosttyRuntime` therefore builds the config itself (`ghostty_config_new` → `load_default_files` → `load_recursive_files` → `finalize`) and pushes it with `ghostty_app_update_config`; `host.reloadConfig()` is unused for the same reason — it hardcodes the injection and keeps the result in a property we cannot reach. `ghostty_config_load_cli_args` stays out too: our argv is `--connect`/`--bridge`, not ghostty flags.
- **A light/dark `theme` pair cannot be resolved through the C API.** libghostty chooses between the halves with its *conditional* config state, which has no C entry point, so `ghostty_config_get` always answers from the default state — `light`. `background` and `foreground` are then the light half whatever the terminal is drawing, which is why `GhosttyConfig.hasLightDarkTheme` (a text scan of the config for a `theme =` with a comma, colon or equals) switches the chrome to AppKit's semantic colours instead of guessing. The appearance is safe without it: ghostty's own `finalize` rewrites `window-theme = auto` to `system` for a pair (`Config.zig`, "theme specifying light/dark changes window-theme from auto").
- **A menu key equivalent is consumed before the surface sees the key.** So a `keybind` trigger with no ⌘/⌃/⌥ must never become one: honouring `keybind = a=…` would stop the user typing that letter anywhere in the app, and libghostty already handles those inside the surface. `GhosttyConfig.shortcut(_:_:)` drops them, along with `catch_all` and the physical keys that depend on the keyboard layout. An unbound action comes back as a zeroed trigger, i.e. physical `unidentified`.
- **`quit-after-last-window-closed` is deliberately not honoured.** It is readable, but ghostty's macOS default is *false* while this app has always terminated with its last window, and the C API cannot tell a default apart from a value the user typed — so honouring it would leave a Dock icon behind for everyone who never set it. Anything else with that shape (a ghostty default that disagrees with an existing deliberate choice here) needs the same judgement, not a reflex.
- **`NSSplitView.dividerColor` has no setter.** `split-divider-color` is applied by overriding the property on `SplitNodeView`, which is how AppKit intends it; assigning to it does not compile.
- Remote scripts must go to `ssh host bash -s` on **stdin**. Extra argv after the host is joined with spaces and executed by zsh, which splits on `;`.
- `HERDR_SOCKET_PATH=.../herdr.sock` makes `herdr terminal session control` open `.../herdr-client.sock`. Forward both or control fails with "No such file or directory".
- Never `FileHandle.write` to a pipe that a child may have closed; EPIPE becomes an ObjC exception and `abort()`s. Use `writeIgnoringBrokenPipe` and keep `HerdrProcess.setUp()` (SIGPIPE ignored) on every entry point.
- Never read a subprocess pipe only after `waitUntilExit()`; that deadlocks past the ~64 KB pipe buffer. `ProcessRunner` drains both streams concurrently — see `processRunnerSurvivesOutputLargerThanThePipeBuffer`.
- `LineBuffer` yields `Data`, not `String`. A non-UTF-8 frame must not end the drain loop while complete records are still queued.
- Launch from a shell (`./Scripts/dev.sh --run` or `swift run HerdrTerm`), not `open` / Finder, or `SSH_AUTH_SOCK` is missing.
- GhosttyKit is arm64 macOS 14+ and an unstable C API — pin the package version.

## UI conventions

- No hardcoded colors. There are exactly two sources: the user's ghostty palette for the *terminal area* (`GhosttyConfig.terminalBackground` / `.terminalForeground`, the split divider and the unfocused-split scrim), and semantic `NSColor`s plus `StatusStyle` for everything else. The chrome stays semantic on purpose — ghostty has no opinion about a sidebar — and `window-theme` is the lever that makes it light or dark, which is why forcing the appearance is enough and tinting the sidebar is not. The sidebar's translucency comes from `NSSplitViewItem(sidebarWithViewController:)`.
- A translucent window is `background-opacity`/`background-blur`, and it only works if *everything* behind the surface is translucent too: `window.isOpaque = false`, the window background and the pane layer carry the alpha, and the blur is an `NSVisualEffectView` pinned to raw bounds so it reaches under the toolbar. An opaque layer anywhere in that stack paints the desktop back out and the setting looks ignored.
- Ghostty settings that describe a *window* are honoured; ones that describe a *pane* usually belong to Herdr instead. `confirm-close-surface` and `focus-follows-mouse` are ours to act on; scrollback, padding, fonts and splits are libghostty's or the server's. When in doubt, ask whether the GUI is the only thing that could implement it.
- The content pane is pinned to `safeAreaLayoutGuide`, not raw bounds — the window uses `.fullSizeContentView` and content would otherwise sit under the toolbar.
- Nothing inside the sidebar may have an opinion about its width. A subview pinned to both edges hugs at 250, which ties with `NSSplitViewItem.holdingPriority`, and the divider then silently refuses to drag at all — that is how `emptyLabel` froze the sidebar at `minimumThickness`. Give any such view hugging and compression resistance of 1.
- `NSSplitViewController` ignores `splitView.autosaveName`: on launch it lays the sidebar out at AppKit's default thickness and autosaves *that* over the width the user dragged to. `SidebarSplitViewController` persists the width itself, and both halves are load-bearing — it restores only once the window has a frame wide enough to honour the stored width (the first layout pass runs narrower than the restored frame and would clamp it to `minimumThickness`), and it saves only when the mouse is down with the pointer on the divider, because `didResizeSubviewsNotification` also fires for a window resize that squeezes the sidebar.
- One vocabulary, everywhere: **host** (a connection), **space** (Herdr workspace), **tab**, **pane**. The sidebar is hosts → spaces, the strip is tabs, the panes are the splits. Menu items and labels use those words, not "workspace".
- `SidebarView.apply` and `TabBarView.apply` reload only when row identity changes and reconfigure cells in place otherwise; a full `reloadData` on every snapshot would throw away scroll position and the user's collapsed hosts.
- A sidebar row is a host or a space, and each says its state one way only: a host gets an icon (tinted when something inside wants attention) and a spinner while it dials, a space gets the status dot. A remembered but unattached host is dimmed, not hidden — selecting it is how the user dials it.
- Pane borders mean two different things: the loud ring is attention (pulsing while blocked), the quiet accent border says which pane of a *split* holds the keyboard. A tab with one pane never draws the quiet one.
- Only the selected host renders. A pane counts as read when it is on screen, i.e. in the selected tab of the visible host (`SessionController.isVisible`), so a split of four panes clears four attention flags.
- libghostty's tick is reference counted by attached panes (`GhosttyRuntime`), not left running at 60 Hz forever.
- Window-scoped key monitors must be removed in `windowWillClose`, or a closed window keeps swallowing ⌘1…⌘9.
- A bridge that exits on its own must **not** be re-attached automatically (`TerminalPaneView.detachedPaneId`); refresh would immediately respawn it and spin. Re-attaching is permission the user grants by picking the pane again, which routes through `MainWindowController.select`.

## Verify

```bash
swift test --filter HerdrClientTests
swift build --product HerdrTerm
.build/debug/HerdrTerm --show-ghostty-config
# needs a running herdr server:
.build/debug/HerdrTerm --self-test local
./Scripts/dev.sh --run --connect local
```

`--show-ghostty-config` is the whole ghostty-config surface in one screen: every
key we read with the value we resolved, and every menu shortcut with whether it
came from a `keybind` or from this app. Point it at a scratch config rather than
editing the user's — ghostty honours `XDG_CONFIG_HOME`:

```bash
mkdir -p /tmp/ghosttytest/ghostty
printf 'background = #101820\nwindow-theme = light\nkeybind = cmd+e=new_split:right\n' \
  > /tmp/ghosttytest/ghostty/config
XDG_CONFIG_HOME=/tmp/ghosttytest .build/debug/HerdrTerm --show-ghostty-config
```

A config key that reads back as its default when the file clearly sets it is
either unexposed by the C API (`ghostty_config_get` returned false) or being
overridden by a theme loaded after it — check `ghostty +show-config` for what
ghostty itself ended up with.

A pane showing a local shell prompt (rather than the remote pane's content)
means the bridge never started. `pgrep -f 'HerdrTerm --bridge'` is empty and the
app has a `/usr/bin/login … /bin/zsh` child instead; libghostty's own log
(`log show --predicate 'subsystem BEGINSWITH "com.mitchellh"'`) shows
`config: default shell source=env`.

In a split, every visible pane must have its own bridge with its own
`--target` and `--control-pipe`:

```bash
pgrep -fl 'HerdrTerm --bridge'
pgrep -fl 'terminal session control'
```

Switching tabs must drop the previous tab's bridges — a leftover means
`SplitContainerView` stopped tearing panes down and the server is feeding frames
to nobody.

A pane that visibly reloads on a timer means the session is reconnecting, not
that rendering is slow. Distinguish the two:

- `~/.config/herdr/herdr-server.log` — repeated `terminal attach client connected` means the pane is being respawned.
- `pgrep -f 'terminal session control'` sampled once a second — a changing PID confirms it.
- The sidebar not reacting to `herdr workspace create` within ~2 s means events are not arriving.
