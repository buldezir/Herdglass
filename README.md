# herdr-term

Native macOS GUI client for remote [Herdr](https://herdr.dev) servers, with a GPU terminal via [libghostty](https://github.com/ghostty-org/ghostty) / [GhosttyKit](https://github.com/briannadoubt/GhosttyKit) and attention rings when an agent is `blocked` or has an unseen `done`.

The window maps straight onto Herdr's own structure:

| Chrome | Herdr |
| --- | --- |
| Sidebar folders | hosts / connections — several can be attached at once |
| Folder children | spaces (Herdr workspaces) |
| Strip above the terminal | the space's tabs |
| The terminal area | the tab's panes, drawn as splits |

Herdr remains the multiplexer; this app does not reimplement panes, agents, or layouts. Splitting, closing and resizing all happen on the server, and the GUI redraws what the server reports — so the same session looks the same in `herdr`'s TUI.

## Requirements

- macOS 14+, Apple Silicon (GhosttyKit 0.8.0 currently ships arm64)
- Local `herdr` on `PATH` (tested with 0.8.2)
- For remote hosts: working OpenSSH (`ssh <host>` already succeeds) and the key loaded in `ssh-agent` (`ssh-add -l`)

## Run

```bash
chmod +x Scripts/dev.sh
./Scripts/dev.sh --run
```

`--run` starts the app from your shell so `SSH_AUTH_SOCK` is inherited. Double-clicking the `.app` (or `open`) often cannot talk to `ssh-agent`.

Or `swift run HerdrTerm`.

Connect with an SSH config Host (the same target you would pass to `herdr --remote workbox`), `ssh://user@host:22`, or `local` to attach to a Herdr server on this Mac. The optional session name matches `herdr --remote host --session agents`.

Hosts you have used before are listed in the sidebar, dimmed, on the next launch; clicking one attaches it. ⌘K adds another host to the same window rather than replacing the current one, and each host keeps its own connection, spaces and selection. Right-click a folder for New Space, Reconnect, Disconnect and Remove Host.

To skip the connect sheet, name the target on the command line:

```bash
./Scripts/dev.sh --run --connect workbox --session agents
```

## How remote attach works

`herdr --remote` is **TUI-only** (`herdr --remote HOST workspace list` is rejected). Non-interactive SSH also skips zsh/Homebrew `PATH`, so herdr-term looks for `/opt/homebrew/bin/herdr` (and a few other install locations) on the remote host. It then:

1. Opens an SSH ControlMaster to the target (`BatchMode`, so keys must already be in the agent)
2. Ensures `herdr server` is running on the remote host (installs nothing; the binary must already be there)
3. Forwards the remote Unix API socket advertised by `herdr status server`
4. Speaks Herdr's NDJSON socket API (`session.snapshot`, `events.subscribe`, `pane.focus`)
5. Renders every pane of the selected tab by spawning one `HerdrTerm --bridge --target <pane> …` per pane, each running `herdr terminal session control <pane> --takeover` and copying `terminal.frame` ANSI bytes into libghostty
6. Reads the tab's split tree from `layout.export` and builds it out of nested split views; dragging a divider sends `layout.set_split_ratio`

Frame / control JSON (Herdr 0.8.2):

- `{ "type": "terminal.frame", "bytes": "<base64>", "encoding": "ansi", "full": true, "width": 80, "height": 24, "seq": 1 }`
- `{ "type": "terminal.input", "bytes": "<base64>" }` or `{ "type": "terminal.input", "text": "..." }` (not both)
- `{ "type": "terminal.resize", "cols": 80, "rows": 24 }`
- `{ "type": "terminal.scroll", "direction": "up" | "down", "lines": 3, "source": "wheel" | "page_key" }`
- `{ "type": "terminal.release" }`

Requests on the API socket are **one-shot**: Herdr answers a single request and closes the connection. Only `events.subscribe` stays open and streams.

Only the selected tab of the selected host is rendered, so only its panes hold bridges — switching tabs or hosts releases the previous ones.

## Shortcuts

| Key | Action |
| --- | --- |
| `⌘K` | Add host… |
| `⌘R` | Reconnect the selected host |
| `⌘N` | New window |
| `⌘T` | New tab in the selected space |
| `⌘W` | Close tab (`⇧⌘W` closes the window) |
| `⌘D` / `⇧⌘D` | Split the active pane right / down |
| `⌘⌥←↑↓→` | Move the keyboard to the pane in that direction |
| `⌘1`…`⌘9` | Tab with that number, in the selected space |
| `⌃⌘1`…`⌃⌘9` | Space with that number |
| `⇧⌘[` / `⇧⌘]` | Previous / next tab |
| `⇧⌘U` | Jump to the pane that needs attention (any host) |
| `⌃⌘S` | Toggle sidebar |
| `⌃⌘F` | Full screen |

Clicking a pane moves the keyboard into it — that is also how the active pane of a split changes, and Herdr is told about it. Arrow keys browse the sidebar without stealing focus. The sidebar is draggable between 180 and 460 pt and its width is remembered.

Closing a tab asks first when it holds more than a bare shell, because `tab.close` closes its panes on the server.

Scrolling the pane scrolls Herdr's scrollback, not a local copy: the wheel becomes a `terminal.scroll` on the server, which then sends the frame for the new viewport.

## Command line

| Flag | Meaning |
| --- | --- |
| `--connect <host> [--session <name>]` | Open a window straight onto a host |
| `--self-test <host> [--session <name>]` | Connect, snapshot, read one control frame, exit |
| `--bridge --target <pane>` | Internal: the PTY child libghostty spawns for a pane (one per visible pane) |

## License

MIT. Ghostty/libghostty is MIT. This repo does not vendor [cmux](https://github.com/manaflow-ai/cmux) (AGPL).
