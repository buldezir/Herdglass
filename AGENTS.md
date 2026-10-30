# Herdglass

Native macOS AppKit GUI client for remote [Herdr](https://herdr.dev) servers. It maps 1:1 onto Herdr's own nouns: **sidebar folders are hosts, their children are spaces (Herdr workspaces), the strip above the terminal is the space's tabs, and a tab's panes are drawn as splits.** Herdr stays the multiplexer; this app owns no panes, agents, or layouts of its own — it renders what the server reports and asks the server to change it.

Rendering uses [libghostty](https://github.com/ghostty-org/ghostty), built by `Scripts/libghostty.sh` from the commit pinned in `Vendor/ghostty` and linked as the `GhosttyKit` binary target. The AppKit glue in `Sources/Herdglass/Ghostty/` is ours.

## Layout

- `Sources/HerdrClient/` — SSH attach, Unix JSON-RPC, `terminal session control` bridge, the herdr release that bridge runs (`HerdrRelease.swift`), models, split-layout tree (`Layout.swift`), a host's files over the SSH master (`RemoteFiles.swift`)
- `Sources/Herdglass/` — AppKit window, sidebar (hosts → spaces), tab strip, split container, connect sheet, Ghostty host view, ghostty-config reader (`GhosttyConfig.swift`), the chrome's type scale (`ChromeMetrics.swift`), the opt-in space keys (`SpaceKeys.swift`), the ⌘`/held-⌥⌘ spaces overlay (`SpaceSwitcher.swift`), settings window and macOS notifications (`AgentNotifications.swift`)
- `Sources/Herdglass/Files/` — the Files card (⌘J): `FileBrowser` (the controller and the tree's data source), `FileBrowserView` (scrim, card, header, banner), `CodeEditorView` (TextKit 1 text view, line-number gutter, background highlighting), `SyntaxLexer` and `SyntaxLanguages` (a table-driven tokenizer, no dependency), `SyntaxTheme` (tokens → the ghostty palette)
- `Sources/Herdglass/Ghostty/` — the libghostty glue: `TerminalHost` (the `ghostty_app_t` and its callbacks), `TerminalSession` (one surface), `TerminalSurfaceView` (the `NSView` and its input)
- `Tests/HerdrClientTests/` — parsing, framing, RPC-transport and remote-file tests
- `Tests/HerdglassTests/` — clipboard conversion, the syntax lexer, the cell under the pointer (`TerminalGridTests`), and where a walk along the spaces starts (`SpaceWalkTests`)
- `Scripts/libghostty.sh` — build `Vendor/GhosttyKit.xcframework` from the pinned ghostty; `--check` compares it with the pin
- `Scripts/dev.sh` — build `.build/Herdglass.app` and optionally `--run` (extra args pass through)
- `Scripts/release.sh` — optimized build at `.build/release-app/Herdglass.app`, `--install` to `/Applications`, optionally `--run`
- `Scripts/appicon.swift` — draws `Resources/Herdglass.icns` with CoreGraphics; the `.icns` is in git, so this runs only when the icon design changes

Entry: `HerdglassMain.swift`. Flags: `--bridge` (PTY child for libghostty), `--connect <host>` (skip the connect sheet), `--self-test <host>`, `--show-ghostty-config` (what the app took from the user's ghostty config, and the menu it produced).

## Architecture

```
GUI  --session.snapshot / events.subscribe / pane.focus-->  forwarded herdr.sock (API)
GUI  --spawns-->  Herdglass --bridge  --herdr terminal session control-->  forwarded herdr-client.sock
```

`herdr --remote` is TUI-only (cannot prefix CLI subcommands). Attach is our SSH ControlMaster:

1. `BatchMode` SSH (key must already be in `ssh-agent`)
2. Find remote `herdr` at Homebrew/mise/Nix/`~/.local/bin` — non-interactive PATH has no Homebrew
3. Ensure `herdr server`, parse `socket:` from `herdr status server`
4. Forward **both** `herdr.sock` (API) and `herdr-client.sock` (direct terminal attach)
5. Focused pane: Ghostty launches `Herdglass --bridge --target <pane> …`, which speaks NDJSON `terminal.frame` / `terminal.input` / `terminal.resize` / `terminal.scroll` / `terminal.release`
6. Scroll wheel and mouse: the GUI writes `terminal.scroll` and `terminal.mouse` to a per-pane FIFO (`PaneControlChannel`, path passed as `--control-pipe`) that the bridge forwards

The app is a ghostty client as much as a Herdr one, so it reads the user's own
`ghostty` config rather than inventing settings of its own: `GhosttyConfig`
snapshots the keys that describe a *window* — colours, opacity, titlebar,
`window-theme`, `confirm-close-surface`, `focus-follows-mouse` — plus the
`keybind`s for the actions this app can perform, and `GhosttyRuntime` owns the
`ghostty_config_t` everything reads from. `--show-ghostty-config` prints the lot,
including which menu shortcuts came from the config and which are ours.

`ConnectionsController` owns the window's hosts — one `SessionController` per host, each with its own SSH master, event stream and selection (space → tab → pane). Only the selected host is `isVisible`, so only its panes have bridges. `MainWindowController` turns all of that into a `SidebarModel`, a `TabBarModel` and a `SplitContainerView.Model`; `StatusStyle` is the only place agent status becomes a color or a word.

A tab's panes are all live at once: `SplitContainerView` builds nested `NSSplitView`s from the tab's split tree, one `TerminalPaneView` (and one bridge) per pane. Dragging a divider is a `layout.set_split_ratio` on the server, so the TUI and every other client see the same geometry. ⌘D / ⇧⌘D are `pane.split`, ⇧⌘arrows are `pane.focus_direction` — the GUI never computes geometry itself.

## Constraints agents should not re-break

The first four interact. Read all four before touching `HerdrRPC` or `SessionController`.

- **The API socket is one request per connection.** Herdr answers `session.snapshot` (etc.) and immediately hangs up, so `HerdrRPC` dials a fresh socket per call. Caching it makes every request after the first throw, which the UI reads as a dropped session and reconnects. Covered by `repeatedRequestsSurviveAServerThatHangsUpEachTime`.
- **`events.subscribe` is all-or-nothing, and pane-scoped types poison it.** `pane.agent_status_changed`, `pane.scroll_changed` and `pane.output_matched` each require a `pane_id`. Including one without it makes Herdr reject the *entire* call, so the client gets no events whatsoever. Keep `HerdrRPC.eventTypes` to session-wide types only — `subscriptionListOmitsPaneScopedEvents` guards this. Check any new type against the schema first:

  ```bash
  herdr api schema --json | python3 -c "import json,sys; \
    [print(v['properties']['type']['const'], [r for r in v.get('required',[]) if r!='type']) \
     for v in json.load(sys.stdin)['schemas']['request']['\$defs']['Subscription']['oneOf']]"
  ```

- **A rejected subscription arrives as a line on the stream, not as a thrown error.** `subscribe` therefore reads the `subscription_started` acknowledgement synchronously and throws on anything else. Without that, a rejection is indistinguishable from a quiet session: the stream stays open and the poll fallback never engages. Covered by `subscribeThrowsWhenTheServerRejectsTheSubscription`.
- **Keep the poll behind the event stream.** Agent status is only pushed by the pane-scoped `pane.agent_status_changed`, which a session-wide client cannot subscribe to, so attention rings would otherwise depend on some other event happening to fire. `SessionController` polls every 2 s alongside events, and every 0.9 s when the server refuses to subscribe us.
- **One request at a time, on one queue, and never more than a few a second.** Every RPC a session makes goes through `SessionController.work`, a serial queue of its own, and `refreshSnapshot` coalesces: one in flight, one queued at most, and a `minimumSnapshotInterval` floor between them. Neither half shows up locally. Over a forwarded socket a request costs a round trip, `pane.updated` arrives faster than that while a pane is printing, and dispatch answers a blocked block by starting another thread — enough concurrent blocking requests exhaust the global pool's 64-thread soft limit, and unrelated AppKit work that needs a pool thread stalls with it. Anything new that talks to the server belongs on `work` too, and `HerdrRPC`'s read timeout is what keeps one stuck reply from stopping the queue for good (`aServerThatNeverAnswersTimesOutRatherThanParkingTheCaller`).
- **`NSOutlineView` reports a selection *after* the click, not during it.** A flag set around `selectRowIndexes` cannot tell our own push apart from the user's click: the notification for the click arrives later, finds the flag raised, and is dropped. `SidebarView` therefore keeps `appliedSelectionId` — the row it last selected itself — reports anything else as the user's, and refuses to push while the outline is sitting on a row it has not reported yet. Anything that syncs a view's selection from the model needs the same shape, not a flag.
- **`herdr status server` exits 0 whether or not a server is running, so only the `status:` line answers that.** A crashed server leaves its socket files behind and still reports `status: not running` *and* a socket path, with exit code 0 — and "not running" contains "running", so a `contains` test is no better than the exit code. `HerdrStatus.isRunning` is the one place that decides (`crashedServerDoesNotReadAsRunning`), the remote bootstrap greps the same line, and it waits for the server it started rather than sleeping — a start that never comes up fails loudly with `/tmp/herdglass-server-$(id -u).log` (per-uid, because a `/tmp` path another user owns is a redirect that fails).
- **The local server Herdglass starts must not be Herdglass's, or ⌘Q never finishes.** On macOS 27 the Dock keeps a quit app's icon up, "running in the background" (`exited-with-subordinates` in `lsappinfo list`), while anything that still counts as the app's is alive. A `herdr server` started as a plain child was exactly that, for as long as the server ran. Three separate things tie a process to the app, and `ProcessRunner.startOutsideThisApp` handles each. A child joins the app's *coalition* and can never leave it, and only launchd can start a process in a new one, so a launchd job starts the server. LaunchServices also lists every job the app *loads* (`loadedJobs:`) and holds the app until that job is unloaded, running or not, so the job is a launcher: `sh` backgrounds the server and boots its own job out, and `AbandonProcessGroup` lets the server outlive it as a child of launchd. And an app launched by LaunchServices has its identity in its environment (`__CFBundleIdentifier`, `LaunchInstanceID`, `XPC_SERVICE_NAME`), which is dropped so neither the server nor its panes claim to be Herdglass. Disclaiming responsibility (`responsibility_spawnattrs_setdisclaim`) fixes none of these and is not needed. The label is unique per start, because booting out a *running* job kills it. None of this shows from a shell launch: there the shell is responsible for everything. Test it with `open .build/Herdglass.app --args --connect local --session <new>` and ⌘Q.
- **`ssh` may not run unbounded, least of all on the main thread.** `RemoteConnection.close()` is called from `windowWillClose`, so `ssh -O exit` gets three seconds and then the app stops caring — `ControlPersist` reaps the master anyway. `ProcessRunner.run` takes a `timeout` for the same reason (`aCommandThatOutlivesItsTimeoutIsKilledRatherThanWaitedOut`).
- **An action from libghostty must have its session resolved before the hop to the main actor, not inside it.** `terminalHostAction` runs on libghostty's thread and hops with `Task { @MainActor }`; resolving `terminalSession(for:)` inside that hop is a use-after-free, because `Unmanaged.takeUnretainedValue()` is a +0 read and the tab can close in between. Resolve it in the callback and let the resulting strong reference carry the session across the hop, which is what `terminalHostCloseSurface` twenty lines below already does.
- **libghostty ignores a surface's `command` and `env_vars`.** `ghostty_surface_config_s` has both fields, `TerminalSession.createSurface` fills them in, and libghostty drops them: the surface runs the login shell instead and no bridge starts. It is neither an ABI mismatch (`working_directory`, the field before `command` in the same struct, is honoured) nor version specific (every build up to the commit in `Vendor/libghostty.version` drops it). The app-level config *is* honoured, so `GhosttyRuntime.useSurfaceCommand` clones the config we loaded, appends `command = shell:…`, and pushes it with `ghostty_app_update_config` before the surface exists. Everything the bridge needs therefore travels in that command line (`BridgeOptions.argv`), never in the surface environment.
- **A surface can fail to be created, and it says so by being null.** `ghostty_surface_new` returns null when the view has no screen — libghostty builds a `CVDisplayLink` from it, and a locked screen is enough to trigger it. Attach the view to the window *before* `session.attach`, and check `session.surface` afterwards: an unchecked nil renders as a working-but-empty terminal.
- **Scrolling cannot ride the PTY.** Everything the surface writes to the bridge's stdin becomes `terminal.input`, i.e. keystrokes for the program in the pane, and libghostty's own scrollback is empty because it only ever sees full viewport frames. Herdr owns the history and moves it only for `{"type":"terminal.scroll","direction":"up"|"down","lines":>0,"source":"wheel"|"page_key","column":…,"row":…,"modifiers":…}` — hence the FIFO side channel, and hence `TerminalPaneView` replacing the view's `scrollWheel` handler instead of letting libghostty handle the wheel. Both ends open the FIFO `O_RDWR` so an idle peer never reads as EOF. `lines: 0` and a bad `direction` make Herdr drop the command. Herdr decides what a wheel means: its own history moves by `lines`, but a program that has taken the mouse gets **one** wheel report per command whatever `lines` says, at `column`/`row` — the top-left cell when they are missing. So `PaneControlChannel.scroll` writes one command of one line per line, as ghostty reports one wheel event per line, and always with the cell under the pointer; without either, a TUI scrolls a third as fast and scrolls whatever panel sits in its top-left corner. `controlChannelFramesScrollCommandsAsNDJSON` pins both.
- **The mouse cannot ride the PTY either, and the frames do not say who wants it.** Herdr strips every mode out of the frames it sends a controller except synchronized output and the cursor, so libghostty never learns that a program asked for the mouse and keeps every click for its own selection — clicks never reached `ra` or any other TUI. Mouse input goes to herdr as `{"type":"terminal.mouse","action":"down"|"up"|"drag"|"move","button":"left"|"right"|"middle","column":…,"row":…,"modifiers":…}` (zero-based cells; Shift 1, Ctrl 2, Alt 4), which herdr encodes for the pane's real mouse mode and **drops** for a program that asked for nothing. libghostty still gets every event too: it is what decides whether a press is the program's or a selection, once it knows.
  - **Who has the mouse is herdr's to say, and herdr up to 0.9.5 does not say it.** The server tells a controller (`ServerMessage::MouseCapture`, on attach and on every change), but `herdr terminal session control` discards the message. The bridge is ready for a herdr that prints it as `{"type":"terminal.mouse_capture","enabled":bool}` — a name of ours, not one herdr has shipped; it was tested with a client that prints it, against a stock server. On that record it writes `?1000h ?1006h` (or `l`) into libghostty (`ControlBridge.libghosttyMouseMode`), which then stops selecting on a plain drag, keeps Shift for selection, consumes a press it would report, and answers `ghostty_surface_mouse_captured` (`TerminalSession.isMouseCaptured`). What libghostty reports back is stripped from the bridge's stdin (`MouseReportFilter`): the GUI has already sent herdr the same click as `terminal.mouse`, and passed on as input it would reach the program twice. Press and release only, in SGR, because an SGR report is the one shape no key produces. With today's herdr libghostty never captures, every press without Shift goes to herdr anyway, and a drag or double-click in a program that took the mouse also draws a selection here; that is the whole remaining gap.
  - `TerminalSurfaceView` follows ghostty's own rules. Not a click that only moves the keyboard into a pane or brings the window forward (`reportsPress`). Then `programTakes`: while libghostty captures, exactly the presses it consumed, which is ghostty's Shift rule and `mouse-shift-capture` too; otherwise any press without Shift. The right button goes to the program only when libghostty consumed it while capturing, and is the context menu otherwise — reported blind, it would open a menu over every right click a program wants. Drags and the release go only with a press that was reported, and motion only when it crosses into another cell (`controlChannelReportsTheMouseOncePerCell`).
- **The cell under the pointer is libghostty's, read back.** Herdr renders at libghostty's grid size, so the cell is libghostty's — but its C API has no point-to-cell call and no getter for `window-padding-x`/`-y` (a plain struct, see `ghostty_config_get` below), and the padding is what decides a row near a cell's top edge. `TerminalSession.gridOrigin` reads it from two calls that do answer: `ghostty_surface_read_text` gives the first cell's left edge exactly and its top as `top + cell height - baseline`, `ghostty_surface_ime_point` gives the cursor cell's bottom as `top + (row + 1) * cell height`, and since the baseline lies inside one cell the remainder of their difference is the baseline. Cached per surface size and cleared on a config reload or a scale change. `TerminalGridTests` pins the arithmetic against libghostty's formulas; a cell's edge pixels are the hand check (below).
- **The Files card reads and writes through `bash -s` and `base64`, and saves *into* the file.** Herdr has no file API, so `RemoteFiles` runs scripts on the host through the session's SSH master (a local `bash` for `local`), on stdin like every other remote script, and every answer comes back base64-encoded because `ProcessRunner` hands stdout over as a `String`. `base64` of nothing is a bare newline, which `Data(base64Encoded:)` refuses even with `.ignoreUnknownCharacters`, so an empty file or folder has to be special-cased (`RemoteFiles.base64`). A read takes a `cksum` token *before* the bytes; a save sends it back and the host exits 4 if the file moved since (`RemoteFiles.isChangedOnHost`, the conflict banner's Overwrite/Reload). The bytes land in a `mktemp` file first and are then copied over the original with `cat >`: a dropped link cannot truncate the file, and writing into it keeps its inode, mode, owner and hard links, which a `mv` into place replaces (`saveWritesIntoTheFileAndKeepsItsModeAndInode`). Decoding asks `base64 -d` once and falls back to `-D` for macOS before 13, because the heredoc can only be read once.
- **The Files card's SSH jobs have a queue of their own, and it is serial.** `SessionController.files` runs on `fileWork`, not `work`: a 4 MB read in front of the poll is an attention ring that stops moving while a file loads. Serial, because each job is an SSH *session* on the master and sshd refuses the eleventh (`MaxSessions`); a burst of folder expansions queues rather than opening ten channels. The connection is resolved per call, so a save after a reconnect goes to the new master, and a result for a connection that has since gone is reported as a disconnect.
- **A folder's listing must not list it again.** Expanding a folder lists it (`outlineViewItemWillExpand`), and the listing redraws it with `reloadItem(_:reloadChildren: true)` — which re-expands every open folder it reloads, the reloaded one included, and posts `itemWillExpand` for each. Taken at face value that is a loop: the folder is listed, redrawn, listed again, and the tree flickers for as long as it is open, one SSH job a round trip. The notification comes *inside* the call, so unlike the sidebar's selection a flag is enough here: `FileBrowser.isRedrawingListing` is up for the length of the reload and the handler ignores what arrives under it. `reloadData` posts nothing.
- **The Files card is anchored to the host and folder it was opened on, and it is modal for the terminal area.** It roots at the git toplevel around the selected pane's cwd (else the cwd, else `$HOME`) once, when it opens. Picking another space or host leaves it where it is, because a document with unsaved edits must keep saving to the host it came from; the sidebar, ⌥⌘↑/↓ and ⌘` stay live beside it. Everything that acts on the tab strip or the panes — tabs, splits, ⌥⌘W, ⌥⌘←/→ — is disabled while it is up, and ⌘W closes the card instead of a pane: the spaces overlay's rule that nothing reaches past the card. It never hides with unsaved edits (⎋, ⌘J, ⌘W, the scrim, closing the window and ⌘Q all ask), so all it keeps between openings is the tree. Anything that hands the keyboard to "the terminal area" goes through `MainWindowController.focusTerminalArea`, which picks the card while it is up — `content.focusActivePane()` directly would type into a pane nobody can see. `focus-follows-mouse` hit-tests for the same reason: a tracking area does not know a view is stacked over it.
- **Find over the editor is not `performTextFinderAction:` on the menu item.** `NSResponder` answers that selector for every view, so such an item is enabled over a pane and takes ⌘F away from the terminal. The Find items send `findInFile:` to the window controller, which enables them only while the keyboard is in the card (`FileBrowser.canFind`) and hands the item on to the text view; the tag is the `NSTextFinder.Action`.
- **File drops and image pastes belong to the pane they started in.** `SessionController.upload` captures its connection and pane id, resolves the foreground cwd (else shell cwd) from a fresh snapshot on `work`, and transfers through the existing SSH master. `FileUpload` stages tar contents before publishing, chooses a numbered name on collision, and streams archives via `ProcessRunner.stdinFile`; file bytes never become terminal input. Only the resulting host-side paths are pasted, without Enter, and a detached surface never receives a completion. `TerminalClipboard` keeps Finder image files intact and converts bitmap clipboard data to PNG. Ghostty's own paste keybindings take the clipboard callback, so that route must support images too: `isReadingClipboardForPaste` distinguishes user key actions from an I/O-thread OSC 52 query, which must not upload anything.
- **The bridge must put its PTY into raw mode.** libghostty hands the child a cooked terminal: `icanon` holds keystrokes until Enter, `echo` paints them locally over Herdr's frames, `isig` turns ^C into a signal that kills the bridge, and `ixon` eats ^S/^Q. `ControlBridge.enterRawMode()` does this before spawning herdr and restores the old settings afterwards. `stty -f /dev/ttysNN -a` on the bridge's tty must show `-icanon -isig -echo`.
- **The first resize of a pane arrives before the bridge can hear it, and SIGWINCH is not queued.** libghostty offers no way to say how big a new surface is — `ghostty_surface_config_s` has no size field, every surface is born 800x600 px, and the real size only reaches it when `TerminalSurfaceView.layout` pushes it, milliseconds after libghostty has forked the bridge against that grid. The first thing that happens to a new pane's PTY is therefore a resize, and it lands while the bridge is between its `TIOCGWINSZ` and arming its SIGWINCH source, where the signal's default action discards it. Nothing ever asks again: herdr keeps the `--cols/--rows` the bridge spawned it with. `ControlBridge.run` therefore reads the size once more after `startWinch` and sends a `terminal.resize` if it has moved — a change earlier than that read is caught by the read, a change later by the source. `bridgeResendsThePTYSizeOnlyWhenItMovedSinceTheSpawn` pins what gets sent.
- **An `NSSplitView` must never be its own delegate.** AppKit's `NSSplitViewSidebar` category answers `respondsToSelector:` by asking the delegate, so `delegate = self` recurses until the stack guard is hit. `SplitNodeView` therefore keeps a separate `SplitNodeDelegate` (and must retain it: `delegate` is weak).
- **The split tree comes from `layout.export`, not from the snapshot.** `session.snapshot` has a `layouts` array, but it is flat — cell rectangles plus a list of splits — and reconstructing the nesting from rounded cell rects is guesswork. `layout.export` returns `first`/`second`/`direction`/`ratio` directly. It is a second round trip, so `SessionController` only asks when `LayoutSummary.signature` for the tab changes; polling the tree every 2 s would double the request rate for nothing.
- **Switching is not reattaching, and the difference is deliberate.** A tab or space the user picks must not respawn bridges, because a respawn *is* a reconnect: new `herdr terminal session control`, new PTY, a full repaint. Two caches make a switch a reparent instead, and both are load-bearing:
  - `SessionController.layoutTrees` keeps one `layout.export` tree per tab, and `prefetchLayouts` fills in the rest of the selected space plus where each other space would land (`preferredTab`, the same choice `selectSpace` makes), one request at a time behind the selected tab's own fetch and chained rather than one per poll. Without a tree the window draws the active pane alone and re-splits a round trip later. A stale tree is still drawn while the refetch is in flight; a tree with a pane that has since closed is not (`usableTree`), or the pane would be a leaf with no bridge behind it.
  - `SplitContainerView` parks the panes that leave the tree instead of tearing them down: unparented, `setOnScreen(false)` so libghostty stops drawing them, bridge and terminal state intact. Bounded by `maxWarmPanes` (LRU by when the pane was last on screen), by `knownPaneIds` (a pane the server stopped reporting is gone), and by the host — `sessionKey` changing drops the lot, because only the selected host renders. `paneViews` therefore holds panes that are *not* on screen: anything counting it to decide "is this a split" or "who needs attaching" has to count the tree's panes instead.
- **`layout.set_split_ratio` addresses a divider by path, not by id.** `path` is one bool per descent from the tab's root split, `false` into `first` and `true` into `second`; `[]` is the root. `splitRatioPathsAreFirstFalseSecondTrue` pins the mapping, because a wrong path silently resizes a different divider.
- **A divider ratio may only be published from the drag itself.** `NSSplitView` reports every resize through `didResizeSubviews`, window resizes included — the same trap as the sidebar width. `SplitNodeView` instead reads the ratio after `super.mouseDown` returns, which is exactly the span of the divider's tracking loop, and re-applies the model ratio in `layout()` only when it differs from what was last applied (otherwise the layout pass fights the drag).
- **Rebuild the pane hierarchy on structure, not on ratios.** `LayoutNode.structureSignature` omits ratios; keying the rebuild on the full tree would tear down and respawn every bridge in the tab on each divider drag. `TerminalPaneView`s are cached by pane id and moved between hierarchies; a pane that left the tree is parked, not torn down.
- **The per-surface command is global, and that is still safe for several panes.** `GhosttyRuntime.useSurfaceCommand` pushes the bridge command through the *app* config before each `ghostty_surface_new`, so attaching N panes in one pass looks like a race. It is not: `ghostty_app_update_config` takes effect before the next surface is created, and a four-pane split really does produce four bridges with four distinct `--target`s (`pgrep -fl 'Herdglass --bridge'`). Attach panes on the main thread, one after another, and do not "optimise" this into anything concurrent.
- **`ghostty_config_get` writes through a `void*`, so the Swift type has to match the Zig field.** libghostty decides the type from the config field (`src/config/c_get.zig`): `bool`, `c_uint` for `u8`/`u32`, `c_short` for `i16`, the field's own float width (`Float` for an `f32` like `font-size`, `Double` for an `f64`), `ghostty_config_color_s` for a colour, `ghostty_config_palette_s` for `palette`, and `const char*` for both strings *and* enum tags. Read a key into something smaller than it writes and you corrupt the stack, silently. It returns false — writing nothing — for a key the C API does not expose and for an optional that is unset, which is how `split-divider-color` says "derive one". Plain Zig structs with no `cval` are simply unreachable: that is why `mouse-scroll-multiplier` and `config-file` are not honoured, and why `theme` and `font-family` (a `RepeatableString`) have to be read from the config text.
- **The config is `GhosttyRuntime`'s, and nothing else may add to it.** It builds it itself (`ghostty_config_new` → `load_default_files` → `load_recursive_files` → `finalize`) and hands it to `TerminalHost(config:)`, which is why `TerminalHost` has no config loading of its own. Anything that injects a default here — a fallback theme loaded after the user's config, say — silently overrides `background`, `foreground`, `palette`, `background-opacity` and `background-blur`, and an app reading those back gets its own opinion rather than the user's. `ghostty_config_load_cli_args` stays out too: our argv is `--connect`/`--bridge`, not ghostty flags.
- **A light/dark `theme` pair cannot be resolved through the C API.** libghostty chooses between the halves with its *conditional* config state, which has no C entry point, so `ghostty_config_get` always answers from the default state — `light`. `background` and `foreground` are then the light half whatever the terminal is drawing, which is why `GhosttyConfig.hasLightDarkTheme` (a text scan of the config for a `theme =` with a comma, colon or equals) switches the chrome to AppKit's semantic colours instead of guessing. The appearance is safe without it: ghostty's own `finalize` rewrites `window-theme = auto` to `system` for a pair.
- **A menu key equivalent is consumed before the surface sees the key.** So a `keybind` trigger with no ⌘/⌃/⌥ must never become one: honouring `keybind = a=…` would stop the user typing that letter anywhere in the app, and libghostty already handles those inside the surface. `GhosttyConfig.shortcut(_:_:)` drops them, along with `catch_all` and the physical keys that depend on the keyboard layout. An unbound action comes back as a zeroed trigger, i.e. physical `unidentified`.
- **`ghostty_surface_read_selection` is the untrimmed dump, not the copy action.** It reaches `Screen.selectionString` with `trim = false` (`Surface.dumpTextLocked`), so it hands back every blank cell that pads a row out to the pane's width. The clipboard belongs to libghostty's own `copy_to_clipboard` action, which formats with `clipboard-trim-trailing-spaces` (default true) and calls back into `TerminalHost`'s write-clipboard callback; `TerminalSession.copySelection` runs it as `copy_to_clipboard:plain` because the bare action defaults to `mixed` and generates an HTML payload the callback discards anyway.
- **`quit-after-last-window-closed` is deliberately not honoured.** It is readable, but ghostty's macOS default is *false* while this app has always terminated with its last window, and the C API cannot tell a default apart from a value the user typed — so honouring it would leave a Dock icon behind for everyone who never set it. Anything else with that shape (a ghostty default that disagrees with an existing deliberate choice here) needs the same judgement, not a reflex.
- **`NSSplitView.dividerColor` has no setter.** `split-divider-color` is applied by overriding the property on `SplitNodeView`, which is how AppKit intends it; assigning to it does not compile.
- Remote scripts must go to `ssh host bash -s` on **stdin**. Extra argv after the host is joined with spaces and executed by zsh, which splits on `;`.
- `HERDR_SOCKET_PATH=.../herdr.sock` makes `herdr terminal session control` open `.../herdr-client.sock`. Forward both or control fails with "No such file or directory".
- **A pane attaches with the server's own herdr release, not with whatever herdr is installed here.** The bridge's `herdr terminal session control` runs on *this* Mac and speaks herdr's private terminal protocol to the forwarded client socket (`protocol:` in `herdr status client`, `protocol` in `session.snapshot`). That protocol has to match the server's exactly, and herdr changes it between releases: 0.8 was 20, 0.9 is 22. Nothing else notices a mismatch. The API, the events and the snapshot all work, the server hangs up on the bridge's handshake (its log shows only a skipped `client_id`), and the window fills in around panes showing `herdr: lost connection to server: server closed connection`. That is how "Herdglass cannot connect to herdr 0.9" looked with a 0.8 herdr on the Mac, and no single install can fix it for a sidebar with hosts on two releases. A server older than 0.9 is not attached at all: `HerdrPaths.terminalClient` refuses it first (`HerdrRelease.isSupported`, `aServerBeforeNineIsRefusedRatherThanAttached`), which fails the connect and `--self-test` alike with a note to upgrade and restart the server, and nothing here keeps an 0.8 path alive. For anything newer it gives a remote host the release its snapshot reports, which `HerdrRelease` fetches from herdr's GitHub releases on first use into `~/Library/Application Support/Herdglass/herdr/<version>/herdr`. It checks the download against the SHA-256 GitHub publishes for the asset, checks that `status client` reports the right version, and renames it into place, so a bridge never starts a half-written binary. A cached copy that stops reporting its version is fetched again. The version comes from the server and becomes a path and a URL, so only a plain `x.y.z` is fetched (`onlyAPlainReleaseNumberIsFetched`); a preview build fails the connect with that reason, as does a release GitHub has no checksum for. The `local` host is the exception, because its server was started by an install here: the first install whose protocol matches is used (by protocol, not by `binaryCandidates` order — `anInstalledClientIsChosenByProtocolRatherThanByPath`), and the release is fetched only when none does, i.e. for a server left running across an upgrade. `--self-test` goes through the same choice. The alternative, running each host's own herdr through the SSH master, needs no download, but every bridge would then be an SSH *session*, and sshd refuses the 11th on one connection (`MaxSessions`, default 10), which is fewer than `maxWarmPanes` plus a split. Forwarded sockets do not count against it, which is why the bridges ride them.
- Never `FileHandle.write` to a pipe that a child may have closed; EPIPE becomes an ObjC exception and `abort()`s. Use `writeIgnoringBrokenPipe` and keep `HerdrProcess.setUp()` (SIGPIPE ignored) on every entry point.
- Never read a subprocess pipe only after `waitUntilExit()`; that deadlocks past the ~64 KB pipe buffer. `ProcessRunner` drains both streams concurrently — see `processRunnerSurvivesOutputLargerThanThePipeBuffer`.
- `LineBuffer` yields `Data`, not `String`. A non-UTF-8 frame must not end the drain loop while complete records are still queued.
- Launch from a shell (`./Scripts/dev.sh --run` or `swift run Herdglass`), not `open` / Finder, or `SSH_AUTH_SOCK` is missing.
- libghostty is arm64 macOS 14+ and an unstable C API — the pin is the `Vendor/ghostty` gitlink, and moving it is its own commit, with `Scripts/libghostty.sh` rerun and `--show-ghostty-config` diffed before and after. The script builds the commit the repository records, not the submodule's checkout, because `git pull` moves the first and not the second: a checkout *behind* the pin it updates, and any other it refuses, so `git add Vendor/ghostty` after checking out the new ghostty and before rerunning it. Building it needs Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`); zig comes down at the version ghostty pins, which is rarely the one Homebrew has.

## UI conventions

- No hardcoded colors. There are exactly two sources: the user's ghostty palette for the *terminal area* (`GhosttyConfig.terminalBackground` / `.terminalForeground`, the split divider and the unfocused-split scrim — and the Files card's editor, whose text is content like a pane's: its background and foreground are the terminal's and its syntax colours are the sixteen ANSI colours, mapped the way `bat --theme=ansi` maps them, in `SyntaxTheme`), and semantic `NSColor`s plus `StatusStyle` for everything else, the card's own chrome included. The chrome stays semantic on purpose — ghostty has no opinion about a sidebar — and `window-theme` is the lever that makes it light or dark. The sidebar's translucency comes from `NSSplitViewItem(sidebarWithViewController:)`.
- A translucent window is `background-opacity`/`background-blur`, and it only works if *everything* behind the surface is translucent too: `window.isOpaque = false`, the window background and the pane layer carry the alpha, and the blur is an `NSVisualEffectView` pinned to raw bounds so it reaches under the toolbar. An opaque layer anywhere in that stack paints the desktop back out and the setting looks ignored.
- Ghostty settings that describe a *window* are honoured; ones that describe a *pane* usually belong to Herdr instead. `confirm-close-surface` and `focus-follows-mouse` are ours to act on; scrollback, padding, fonts and splits are libghostty's or the server's. When in doubt, ask whether the GUI is the only thing that could implement it.
- The content pane is pinned to `safeAreaLayoutGuide`, not raw bounds — the window uses `.fullSizeContentView` and content would otherwise sit under the toolbar.
- Nothing inside the sidebar may have an opinion about its width. A subview pinned to both edges hugs at 250, which ties with `NSSplitViewItem.holdingPriority`, and the divider then silently refuses to drag at all. Give any such view hugging and compression resistance of 1.
- `NSSplitViewController` ignores `splitView.autosaveName`: on launch it lays the sidebar out at AppKit's default thickness and autosaves *that* over the width the user dragged to. `SidebarSplitViewController` persists the width itself, and both halves are load-bearing — it restores only once the window has a frame wide enough to honour the stored width (the first layout pass runs narrower than the restored frame and would clamp it to `minimumThickness`), and it saves only when the mouse is down with the pointer on the divider, because `didResizeSubviewsNotification` also fires for a window resize that squeezes the sidebar.
- The app's own settings are the ones neither ghostty nor Herdr can express — how this behaves as a *macOS app*. That is two today (notifications, and the size of the chrome) and should stay small: a setting that describes a terminal belongs in the ghostty config, and one that describes a pane belongs to the server.
- **No hardcoded font sizes either, and a size is never only a font.** Every font in the chrome is `ChromeMetrics.font(_:weight:)` and every length that has to keep step with one is `ChromeMetrics.length(_:)` — a sidebar row's height, a tab's fixed width, a status dot, an SF Symbol's point size. The numbers at the call sites are relative to a base of 12 (the sidebar title), so the type scale stays readable in the code. Scaling the text alone is what makes the setting look broken. Views that outlive a snapshot (`SidebarView`, `TabBarView`, `PlaceholderView`) re-read on `ChromeMetrics.didChangeNotification` — an `NSOutlineView` recycles its cells by identifier, so a cell that sets its fonts only in `init` never hears about the change.
- **⌘W closes the pane in a split and the tab otherwise, and that is `close_surface`, not `close_tab`.** Both ghostty actions are honoured, on ghostty's own keys (⌘W and ⌥⌘W), because they do different things: Close is "what is in front of me" and Close Tab is the whole tab either way. `MainWindowController.closePane` is the one place that decides, from the pane count of the selected tab, and both routes confirm on `confirm-close-surface` — `unlessTrivial` asks about an agent and lets a bare shell go. Nothing moves the selection or the split tree afterwards: `pane.close` takes the pane out of the next snapshot, `settleSelection` follows whatever Herdr focused instead, and the tree is refetched because its signature moved. Herdr closes the tab itself when the pane was its last.
- One vocabulary, everywhere: **host** (a connection), **space** (Herdr workspace), **tab**, **pane**. The sidebar is hosts → spaces, the strip is tabs, the panes are the splits. Menu items and labels use those words, not "workspace".
- **A space and a tab are named after what is running in them, and the name Herdr reports is not enough on its own.** `SessionSnapshot.title(ofTab:)` / `title(ofWorkspace:)` are the only places that decide, and both have a trap:
  - **The agent's *name* is on `agents`, not on the pane.** A pane carries the agent *kind* (`agent: "claude"`) and `display_agent` is simply absent; the name somebody gave it (`herdr agent start reviewer …`, `herdr agent rename`) lives on `AgentInfo.name` alone, keyed by `pane_id`. Hence `agentName(forPane:)`, and hence `paneTitle(_:)` rather than `PaneInfo.displayName` wherever a title is user-facing.
  - **`TabInfo.number` is not the tab's position.** It is a stable ordinal with gaps, so position is `index + 1` in `tabs(in:)` (`SessionSnapshot.position(ofTab:)`) and nothing else. Nothing draws a position any more, but `title(ofTab:)` still needs it to recognise Herdr's own label for an unnamed tab. `tabPositionIgnoresTheGapsInHerdrsNumbering` and `aTabPastTheFirstStillFollowsWhatIsRunningInIt` pin it.
  - **A space says where, a tab says what.** `title(ofWorkspace:)` is a place (a name somebody typed, else the live directory) and `tabSummaries(inWorkspace:)` is what is running, one entry per tab, on the row's second line. Naming a space after the agent inside it makes the one row that should anchor you in a host a second copy of the tab strip.
  - **A space's default label cannot be told from a chosen one, only guessed at.** Herdr names a space after the directory it was created in (`herdr workspace create --cwd ~/projects/app` with no `--label` gives `app`; a home directory gives `~`), so the only test is whether the label still matches a directory the space is in (`labelLooksChosen`). It fails one way on purpose: a space still on its default label whose panes have `cd`'d elsewhere reads as hand-named and keeps the directory it started in. Guessing the other way would throw away a name the user typed with no way to get it back. `aSpaceThatHasMovedKeepsTheLabelItCannotVerify` pins it.
  - The cwd beats `terminal_title_stripped` in `PaneInfo.displayName` because a shell's own OSC title is `user@host:~`, which says nothing the window does not. The OSC title is a last resort, not the name.
- **A tab in the strip is a fixed width, and its close button is not in the stack.** Both are what stop the strip shuffling. An `NSStackView` drops a hidden view from its layout, so a `close` inside it widens the tab the instant the pointer touches it — it is pinned to the trailing edge instead, and faded rather than hidden (and disabled with it, or an invisible close button is still hit-tested). A width that follows the text would move the strip every time a title changed, which is, by design, whenever an agent starts or a pane changes directory. `TabItemView.width` is the one number; the label truncates against the close button.
- **A text field in the connect sheet carries no action of its own.** `NSTextField(string:)` comes with `sendsActionOnEndEditing` set, so a field wired to Connect fires it when focus *leaves* — Tab from Host to Session, a click into Session, or a pick from the known-hosts popup. Return already connects through the default button's key equivalent, and `NSControl.stringValue` reads the live field editor, so nothing is lost by leaving the fields actionless.
- **A sidebar subtitle truncates at the tail.** It is a space's tabs in order, and the first is the one most likely wanted. `.byTruncatingHead` is right for a path and exactly wrong for a list.
- `SidebarView.apply` and `TabBarView.apply` reload only when row identity changes and reconfigure cells in place otherwise; a full `reloadData` on every snapshot would throw away scroll position and the user's collapsed hosts.
- A sidebar row is a host or a space, and each says its state one way only: a host gets an icon (tinted when something inside wants attention) and a spinner while it dials, a space gets the status dot. A remembered but unattached host is dimmed, not hidden — selecting it is how the user dials it.
- Pane borders mean two different things: the loud ring is attention (pulsing while blocked), the quiet accent border says which pane of a *split* holds the keyboard. A tab with one pane never draws the quiet one.
- Only the selected host renders. A pane counts as read when it is on screen, i.e. in the selected tab of the visible host (`SessionController.isVisible`), so a split of four panes clears four attention flags.
- **A pane off screen says so through macOS, not through a blinking toolbar.** Herdr's own notion of a notification is a background agent changing state, and its config picks the delivery (`[ui.toast] delivery`). A GUI client has no toast layer and no outer terminal, so `AgentNotifications` takes the OS route on Herdr's behalf. Three rules keep it quiet: notify on the *transition* into `blocked`/`done`, never on a state that is merely still true; skip a reason a pane has already been notified about (`SessionController.notifiedReasons` — Herdr's detection genuinely flaps `blocked → working → blocked` inside a second while an agent redraws its prompt); and withdraw the notification the moment the pane is read, so `markRead` and Notification Center say the same thing. One identifier per pane (`pane-<id>`) is what makes the last two possible.
- **One window, one instance, and both halves are load bearing.** `AppDelegate` holds a single `MainWindowController` and has no action that makes another; `HerdglassMain` turns a second *process* away by handing the screen back to the `NSRunningApplication` already registered for the bundle. Neither half is enough alone: the Finder refuses a second launch but `open -n` and the binary run out of `.build` do not, and no amount of process checking stops a ⌘N. Two of anything here means two clients dialling the same remembered hosts. The `--bridge` children exec the same binary and return before the check; they never build an `NSApplication`, so LaunchServices does not register them (`--show-ghostty-config` and `--self-test` return before it too, and stay runnable while the app is up). `new_window` and `close_all_windows` are gone from `GhosttyConfig.Action` for the same reason: a keybind cannot move a menu item that does not exist.
- **A ghostty *default* does not move a menu item that shipped with a key of its own; a `keybind` the user wrote does.** `ghostty_config_trigger` answers from the merged config and cannot say where a trigger came from, so `GhosttyConfig.isRebound` asks a second, unloaded `ghostty_config_new` for the stock trigger and compares. It is what lets ⌥⌘↑/⌥⌘↓ be Previous/Next Space here even though ghostty's defaults put `goto_split:up`/`down` on those keys; the splits take ⇧⌘arrows instead. What a *typed* `keybind` claims, it gets — and `surrenderShortcuts` then takes that combination off whatever item was still wearing it, because two items on one key is one item silently dead. An item with *no* built-in key takes ghostty's default only where no other item ships on that key: Reload Terminal Config gets ⇧⌘,, and Open Terminal Config does not get ⌘,. A config that re-types a ghostty default cannot be told from the default, and that is the one case this gets wrong on purpose.
- **⌘, is Settings…, not ghostty's `open_config`.** Both want it, and a duplicate key equivalent in one menu is silently given to whichever item comes first. A ghostty default is no stronger a claim than this app's own, and ⌘, is the key a Mac user presses for an app's settings, so `applyGhosttyTriggers` lends a ghostty default only to a key no item is already wearing (`wornShortcuts`). Open Terminal Config therefore ships without a key. A keybind the user *wrote* still wins: `applyGhosttyShortcuts` collects what the keybinds claimed, and anything else holding that shortcut surrenders it, so `keybind = super+,=reload_config` takes ⌘, off Settings and `keybind = super+shift+o=open_config` gives Open Terminal Config a key of its own. Spell it `super+,`: ghostty reads `super+comma` as a *physical* key, which `GhosttyConfig.shortcut` drops. Anything new with a built-in key equivalent inherits both halves for free.
- libghostty's tick is reference counted by attached panes (`GhosttyRuntime`), not left running at 60 Hz forever.
- **A number on a row has to be a key that answers it.** `SidebarModel.Row.shortcut` carries the key already rendered, `MainWindowController` fills it in for the first nine rows of the sidebar as a whole — read off `orderedSpaces`, the list the keys index, so the nth hint and the nth key are one row by construction — both sides read the modifiers from `SpaceKeys.modifiers`, and the monitor indexes by row alone. Never by `WorkspaceInfo.number`: every host numbers its own spaces from 1, and the numbers have gaps. The hint is dim and right-aligned, and `BadgeView` takes that corner when there is unread — the tooltip is where the key goes then. Anything that wants to draw a number on a row of chrome answers this first: which key is it, and does that key reach this row right now?
- **A collapsed host's spaces are not on the walk.** `orderedSpaces` leaves out every host folded away in the sidebar (`SidebarView.collapsedHosts`), so its spaces take no ⌥⌘ digit, ⌥⌘↑/↓ step over it, and the overlay draws no tile for it — a hidden row holding ⌥⌘1 put every row on screen a key further away. Collapsing or expanding renumbers the hints at once (`onCollapsedHostsChange`), not at the next snapshot. The space on screen can then be off the list, so a walk starts from `SpaceSwitcherModel.Origin`: `.tile` when the window's space is listed, `.between` otherwise, at the place the selected host holds in the sidebar, so a step goes to the host's neighbours rather than to an end of the list. The overlay opened by a hold on `.between` highlights nothing, and letting go of nothing switches nothing. `SpaceWalkTests` pins the steps.
- **The prefix is the level.** ⌥⌘ is tabs and spaces (⌥⌘arrows to step, ⌥⌘1…⌥⌘9 to jump, ⌥⌘T for a new space, ⌥⌘W to close a tab), ⇧⌘ is the splits inside a tab, and a key that means "space" on one keystroke and "split" on the next is worse than either. The digits cannot go to ⇧⌘: ⇧⌘3…⇧⌘6 are the system's screenshot hotkeys, taken above the app on a stock Mac.
- **Tabs have no number, anywhere.** Not in the strip, not in a sidebar row's list of them, and no key selects one by position — `goto_tab` is no longer even read out of the ghostty config. A tab is named after what is running in it and reached by clicking it or with ⌥⌘←/→.
- **⌥⌘1…⌥⌘9 are off until Settings turns them on**, and that is `SpaceKeys` — the modifiers, the nine positions, the `isEnabled` default and the notification that redraws the hints. They cost nine chords a client swallows before the pane sees them and nine numbers drawn on the sidebar; ⌥⌘↑/↓ reach the same rows, so the default costs a keystroke rather than a capability. The monitor asks `isEnabled` per keystroke instead of installing and removing itself — one answer to "is this key mine", and no window left holding a stale one — and `buildSidebarModel` asks once per model so the hints cannot start at 4. `SpaceKeys.didChangeNotification` and the `refresh` observer are what number the rows in front of the user when it is switched on.
- Window-scoped key monitors must be removed in `windowWillClose`, or a closed window keeps swallowing ⌥⌘1…⌥⌘9.
- **The spaces overlay defers the landing; that is the whole feature.** ⌥⌘↑/↓ and ⌥⌘1…⌥⌘9 both *land* on a space — the host selection moves, the panes being left are parked, the keyboard goes with them and the server is told — so walking six spaces to find one switches six times to arrive once. `SpaceSwitcher` is the same walk with the landing held back until ⌘ comes up (⌘` to step, ⇧⌘` back, or ⌥⌘ held for `holdDuration` to look without stepping), and it is the only one of the three that shows the list. Three rules keep it honest: the list is **frozen** when the gesture opens, because snapshots keep arriving and an index that moves under a held key commits a space other than the one on screen; committing the space that is already current does **nothing**, since pushing the selection again would take the keyboard off whatever has it; and every arrow belongs to the card, ⌥⌘←/→ and ⌥⌘↑/↓ included, so nothing reaches past it to switch a tab behind it — the monitor swallows them and `step(tabsBy:)`/`step(spacesBy:)` check `isOpen` as well, because a menu item that gets its key first must not act either. The grid is rows the window's width decided with the tiles spread evenly over them, so seven spaces in a six-wide window are 4 + 3 rather than a full row with an orphan under it. The arrows move over that grid, ←/→ a tile and ↑/↓ a whole row (a tile, when the tiles fit on one row), and they come off `keyCode`: `unshifted` answers with the ASCII cursor control, never the `NSUpArrowFunctionKey` spelling a menu's key equivalent uses, so a character comparison matches nothing. Its tiles are the sidebar's row vocabulary (`StatusDotView` and `BadgeView` live next to `StatusStyle`), and the digits answer inside it whether or not Settings turned ⌥⌘1…⌥⌘9 on — the overlay spends neither the chords nor the always-up sidebar numbering, so it draws the number that answers it while it is up.
- **The overlay is a view over the terminal area, not a floating panel.** A panel would take key window, and the two monitors driving the gesture are `isKeyWindow`-scoped — the release that commits would never arrive. It sits inside the safe area like the strip and the panes, and its dim is ghostty's `terminalBackground` at partial alpha rather than a semantic grey, the same rule the unfocused-split scrim follows.
- **A gesture that ends outside the window has to end.** ⌘⇥ away mid-hold is a `flagsChanged` this window never sees, so `windowDidResignKey` cancels the overlay and the pending hold; without it the app comes back with a card up and a keyboard that has moved on.
- **A structural change takes the first responder with it, so something has to put it back.** `rebuild` unparents every pane view to re-nest it, and a closed pane or tab tears its view down; AppKit answers both by making the *window* the first responder, which is nowhere. `SplitContainerView.restoreFocusIfLost` fills the vacancy, and only a vacancy: anything still a real view in a window keeps the keyboard, which is what stops it fighting "arrow keys browse the sidebar without stealing focus". It runs on a rebuild or a moved active pane, never on the two-second poll — on every snapshot it would pull the keyboard out of the chrome a second after the user put it there.
- **Moving between splits has to move *this client*, not just the server.** `pane.focus_direction` changes Herdr's focus and answers with the pane it landed on (`PaneFocus.focusedPaneId`); `settleSelection` only ever fills a selection that has gone *missing*, so a client that throws the answer away keeps its accent border and its keyboard where they were. `focusNeighbour` adopts the id through `selectPane`; `no_neighbor` answers with the pane it started from, so an edge press lands on itself. Same shape as `pendingPaneId` below.
- **Which pane of a split a tab comes back to is this client's to remember.** Herdr's `focused` flag marks the one pane the *server* is in, so every tab the user is not currently looking at reports no focused pane at all. `SessionController.lastPaneByTab` records where each tab was left (from `selectPane` and from every settle), `preferredPane` and `settleSelection` prefer it over the server's focus, and it is pruned with the tabs. A pane asking for attention still wins, as it does for tabs.
- **A split has to land on the pane it just made.** `pane.split` is sent with `focus: true`, so the *server* focuses the new pane, but `settleSelection` keeps this client's selection on the pane that was split — it still exists — and the two then disagree. `splitSelectedPane` therefore adopts the returned id through `pendingPaneId`, the same shape as `pendingTabId` and for the same reason (the pane is in no snapshot yet).
- A bridge that exits on its own must **not** be re-attached automatically (`TerminalPaneView.detachedPaneId`); refresh would immediately respawn it and spin. Re-attaching is permission the user grants by picking the pane again, which routes through `MainWindowController.select`.
- **The sidebar's order is a rule at both levels, and neither level is "most recent" or the server's array order.** Hosts are `ConnectTarget.precedes`: `local` first — it is the one host that is not somewhere else — then every remote by `localizedStandardCompare`, which is alphanumeric rather than alphabetical (`box2` before `box10`, case deciding nothing) and then by session, so a host with several named sessions is one block. Computed on the way out of `RecentsStore.load()` rather than stored, so it is the same on every launch; the *stored* list stays in the order hosts were added, and `remember`'s 12-host cap is the only thing that may read it (`stored()`), because "which one falls off the end" is an age question the sidebar's order cannot answer. `ConnectionsController.connect` inserts a new row at its place rather than appending, or a host added mid-session obeys the rule only after a restart. Spaces are `SessionSnapshot.orderedWorkspaces`, by `number` (Herdr's own stable ordinal) with the id breaking ties, because `sorted` is not stable and a tie that lands differently on each poll is a shuffle two seconds apart. `number` is the sort key and *only* the sort key: it has gaps, so the rows are named by position the way the tab strip is, and ⌥⌘1…⌥⌘9 count rows when they are on. `localLeadsAndRemotesSortByName`, `hostOrderCountsDigitsRatherThanSpellingThem`, `sessionsOnOneHostStayTogether`, `spacesComeBackInHerdrsOwnOrder`, `spacesSharingANumberStillHaveOneOrder` and `spacePositionIgnoresTheGapsInHerdrsNumbering` pin the lot. The connect sheet's prefill is the one place that still wants "most recent", and it takes `RecentsStore.selectedHost()`.
- **A restored selection is one snapshot's worth of intent, and it belongs to `settleSelection`.** `RecentsStore.Selection` remembers the space, tab and pane per host (ids, so a server that has restarted simply misses and falls through to its own focus), plus one `selectedHost` for which host the window was showing — only one renders, so without it a relaunch restores every host's selection and then shows whichever is first. `finishConnect` reads the record into `restoring`, and the first `settleSelection` after that consumes it and clears it whether the ids fitted or not: a record that outlived one snapshot would keep pulling the window off whatever the user had since clicked. It is written from every place the selection moves (the `select*` methods *and* the settle after each snapshot), because quitting and closing the window announce themselves to nothing — and it never writes an empty selection over a real one. Restoring also pushes `pane.focus`, but only for a pane it really restored and only on the visible host: four hosts coming back at launch must not move the focus on three servers where somebody may be working in the TUI.
- **The hosts to dial at launch are written when a host comes up, never when one goes down.** `RecentsStore.attached()` is a second list beside the recents, added to by `SessionController.finishConnect` and removed from only by `ConnectionsController.disconnect` and `forget` — the two places the *user* detaches a host. It cannot be a flag that `SessionController.disconnect()` clears, because closing the window and quitting the app both tear every session down through `disconnectAll`, so the flag would be cleared by the very quit it exists to survive. Restoring also belongs to a launch with nothing named on the command line (`MainWindowController(restoringHosts:)`): `--connect somewhere` asked for one host, not for the remembered ones alongside it. Each dial carries an empty completion on purpose — a host that has gone away reports itself by its sidebar row going to `failed`, and four restored hosts must not open four modal sheets over a window nobody has touched yet.

## Verify

```bash
swift test --no-parallel
swift build --product Herdglass
.build/debug/Herdglass --show-ghostty-config
# needs a running herdr server:
.build/debug/Herdglass --self-test local
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
XDG_CONFIG_HOME=/tmp/ghosttytest .build/debug/Herdglass --show-ghostty-config
```

A config key that reads back as its default when the file clearly sets it is
either unexposed by the C API (`ghostty_config_get` returned false) or being
overridden by a theme loaded after it — check `ghostty +show-config` for what
ghostty itself ended up with.

`--self-test` prints the herdr it attaches with (`terminal client …`) and the
server's protocol. For a remote host that is
`~/Library/Application Support/Herdglass/herdr/<server version>/herdr`, and the
first self-test against a new version downloads it. Delete the directory to
watch a fetch happen again. `pgrep -fl 'terminal session control'` shows the
same path for a running window's bridges.

The mouse needs a program that asks for it, and a log of what it hears. Run
one in a pane (any session will do; a scratch `herdr --session mousetest server`
keeps it off your own):

```bash
python3 -c 'import sys,os,tty; tty.setraw(0); os.write(1,b"\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[6;11H\x1b[41m \x1b[0m")
while True: os.write(1, repr(os.read(0,64)).encode()+b"\r\n")'
```

Clicking the red cell must print `\x1b[<0;11;6M` and `…m` (1-based in the
report), including on its very top and left pixel rows, and the pixel just above
or left of it must be the neighbouring cell — that is the padding read-back. One
notch of the wheel over it must print three `\x1b[<64;11;6M`, a drag one report
per cell crossed, and Shift-click nothing but motion. Then quit it and run
`cat -v`: clicks and drags must print nothing, a drag must still select text,
and the wheel must still move Herdr's history (`herdr pane get <pane>`,
`offset_from_bottom`). Reset the pane afterwards (`printf '\ec'`): a program
killed in mouse mode leaves it on, and Herdr then rightly sends the wheel to the
shell.

A pane showing a local shell prompt (rather than the remote pane's content)
means the bridge never started. `pgrep -f 'Herdglass --bridge'` is empty and the
app has a `/usr/bin/login … /bin/zsh` child instead; libghostty's own log
(`log show --predicate 'subsystem BEGINSWITH "com.mitchellh"'`) shows
`config: default shell source=env`.

In a split, every visible pane must have its own bridge with its own
`--target` and `--control-pipe`:

```bash
pgrep -fl 'Herdglass --bridge'
pgrep -fl 'terminal session control'
```

Switching tabs must *keep* the previous tab's bridges — up to
`SplitContainerView.maxWarmPanes` of them — so coming back is a reparent and not
a reconnect. Sample `pgrep` across a few tab switches (⌥⌘←/→): the pids stay put, and
`grep -c 'terminal attach client connected' ~/.config/herdr/herdr-server.log`
does not move. A pid that changes on every switch is the old behaviour back.
What must still drop panes: closing the tab on the server, switching hosts,
Disconnect, and going past the warm cap. After any of those,
`pgrep -f 'terminal session control'` has to come back down.

Notifications need an agent status to move, and no CLI sets one — Herdr detects
it from the pane's process name and its output (`herdr agent explain <pane>`
prints the rule that fired). A fake agent is enough to drive the whole path:

```bash
mkdir -p /tmp/fakeagent
printf '#!/bin/bash\necho "Bash command"\necho "Do you want to proceed?"\necho "  1. Yes"\necho "  2. No"\nread -r _\n' \
  > /tmp/fakeagent/claude && chmod +x /tmp/fakeagent/claude
# in a space the window is NOT showing:
herdr pane run <pane> 'PATH=/tmp/fakeagent:$PATH claude'
herdr agent explain <pane>   # state: blocked, rule: bash_permission_prompt
```

The pane then goes `blocked`, one notification is posted, and switching the
window to that space withdraws it. `UNUserNotificationCenter.getDeliveredNotifications`
is the check that macOS really took it — a banner may be suppressed by a Focus
mode while the notification is still delivered.

The base font size has to move boxes as well as text, and the only way to see
that is to walk it to both ends of `ChromeMetrics.range` in Settings and look:
sidebar subtitles must not clip, tab titles must not truncate at four
characters, dots and icons must stay beside the text they belong to, and the
strip must not overlap the terminal.

The Files card is checked by hand, on `local` and on a remote host. ⌘J opens it
on the repository the selected pane is in; expand a folder, open a Swift, a JSON
and a Markdown file and check they are coloured from the palette, then a binary
and a file over 4 MB, which must say why they are not shown. Edit, ⌘S, and check
on the host that the contents changed and `stat` shows the same mode and inode.
Edit again, change the file from a pane (`echo x >> file`), ⌘S: the conflict
banner, and both of its answers. With an edit pending, ⎋, ⌘J, ⌘W, a click on
the scrim, closing the window and ⌘Q must all ask. While the card is up ⌘D, ⌥⌘W
and ⌥⌘←/→ do nothing, and `pgrep -fl 'Herdglass --bridge'` shows the same pids
before, during and after: the card must never respawn a bridge. With the card
closed, ⌘F in a pane must behave as it did before the card existed.

Closing is two paths, and the split one is the new one:

```bash
herdr pane list | python3 -c 'import json,sys; [print(p["pane_id"], p["tab_id"]) for p in json.load(sys.stdin)["result"]["panes"]]'
```

⌘D then ⌘W must leave the tab with one pane, not close the tab; ⌘W again must
close the tab. ⌥⌘W must close the tab from a split too.

Navigation is four arrows on two levels, and `--show-ghostty-config` prints what
the menu ended up with without launching anything: ⌥⌘←/→ walk the tab strip,
⌥⌘↑/↓ walk every attached host's spaces as one list — the last space of one
host steps into the first of the next, and the sidebar selection follows — and
⇧⌘arrows move the keyboard between the panes of a split, one level down. A
`keybind` of the user's that lands on those arrows takes them, and the split
item then has no key at all rather than a key it shares — `super+shift+right=next_tab`
is the collision to try in a real config.
⌥⌘T makes a space on the selected host, and `--show-ghostty-config` is the
check that it is still the only item wearing that key. ⌥⌘1…⌥⌘9 pick a space by
its row down the *whole* sidebar, hosts included, once Settings has turned them
on, and the hint the row draws is the check: switch them on and watch the rows
number themselves, press what one says and land on it, with two hosts attached,
and see the hints run 1…9 straight through the host boundary and stop. Switch
them off and the hints go and the digit reaches the pane again.
With two hosts attached and one merely remembered, the walk must skip the
parked one rather than dialling it. Collapse the first host in the sidebar: the
hints must restart at 1 on the next host's first space at once, ⌥⌘↑/↓ must step
over the collapsed host, and expanding it must give its numbers back. Collapse
the host the window is showing and step: ⌥⌘↓ lands on the space below that host,
⌥⌘↑ on the one above, and a two-second ⌥⌘ hold followed by letting go must
leave the window where it was.

The spaces overlay is a gesture, so it needs the whole of it tried by hand: ⌘`
opens it and steps, held ⌘ with more ` presses keeps stepping and ⇧ goes back,
←/→ move one tile and ↑/↓ a whole row of the grid — narrow the window until the
tiles wrap to check the second — a digit jumps to one of the first nine, and **nothing
switches until ⌘ comes up** — watch the sidebar selection and the pane, which
must not move while the card is up. ⎋ leaves it where it was; a click on a tile
takes it and a click on the dimmed terminal does not. Then hold ⌥⌘ with nothing
else for two seconds: the same card, on the space already showing, and letting go
must change nothing. The cancel is as important as the open — ⌥⌘T, ⌥⌘W and
⌥⌘arrows must never put the card up, however slowly the second key follows. With
one space attached there is nothing to choose between and the card must not
appear at all. ⌘` is macOS's own "next window in this app": it is free here
because there is one window, but it is the kind of combination the system has
been known to take above the app, so it needs a real keyboard and not a
synthesised event.

**A shortcut the menu carries is not a shortcut the app receives.** The splits
were on ⌃⌥⌘arrows first, and that combination never reached the app from a real
keyboard, though the menu held it, AppKit matched it, and synthetic key events
drove it end to end — something above the app was taking it. Synthetic events
are how the *action* gets tested here; only a hand on the keyboard tests the
*key*. Anything moved onto a new combination needs both.

⌘Q has to take Herdglass out of the Dock even when it started the local
server, and the server has to keep running. Launch through LaunchServices with a
session nobody is running, because a shell launch hides the problem:

```bash
open .build/Herdglass.app --args --connect local --session quitcheck
# ⌘Q, then:
lsappinfo list | grep -c '"Herdglass"'        # 0; an exited-with-subordinates entry is the bug
pgrep -fl 'session quitcheck server'           # still running, parent 1
launchctl list | grep -c dev.herdglass.launch  # 0: the launcher job removed itself
herdr --session quitcheck server stop
```

Restoring hosts is a two-launch check, and `disconnect` is the half that is easy
to get wrong:

```bash
# The key prefix predates the Herdglass rename and was kept so existing
# installs keep their state; see the note in RecentsStore.swift.
defaults read dev.herdr.term herdr-term.attached   # the hosts the next launch dials
defaults read dev.herdr.term herdr-term.recents    # every host, oldest added first
```

Attach a host, quit, relaunch with no `--connect`: it comes back attached. Then
**Disconnect** it and read the key again — it must be gone, and the launch after
that must leave the row parked.

`herdr-term.recents` is *not* the sidebar's order — that is computed from it, so
the check is the sidebar itself: `local` at the top and the remotes alphanumeric
under it, the same on every launch however the hosts were added. Attaching a new
host mid-session must put its row in that order straight away, not at the bottom
until the next launch.

Coming back to the same screen is the two-launch check next to it:

```bash
defaults read dev.herdr.term herdr-term.selection      # space/tab/pane per host
defaults read dev.herdr.term herdr-term.selected-host  # the host that renders
```

Pick a space that is not the first, a tab that is not the first, and a pane that
is not the first of a split; quit; relaunch. All three come back, the keyboard is
in that pane, and `herdr pane list | grep focused` agrees. Then move Herdr's own
focus elsewhere from the TUI (or `herdr pane focus <other>`) while the app is
down: the relaunch must still land where the *app* was, and the pane it lands on
must become the focused one on the server. With two hosts restored, only the
visible one may push that focus — check the background host's `focused_pane_id`
did not move.

A pane that visibly reloads on a timer means the session is reconnecting, not
that rendering is slow. Distinguish the two:

- `~/.config/herdr/herdr-server.log` — repeated `terminal attach client connected` means the pane is being respawned.
- `pgrep -f 'terminal session control'` sampled once a second — a changing PID confirms it.
- The sidebar not reacting to `herdr workspace create` within ~2 s means events are not arriving.
