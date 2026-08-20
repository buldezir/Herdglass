# herdr-term

Native macOS GUI client for a remote [Herdr](https://herdr.dev) server. The window is intentionally cmux-like — a vertical workspace sidebar, a GPU terminal via [libghostty](https://github.com/ghostty-org/ghostty) / [GhosttyKit](https://github.com/briannadoubt/GhosttyKit), and attention rings when an agent is `blocked` or has an unseen `done`. Herdr remains the multiplexer; this app does not reimplement panes or agents.

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
5. Renders the focused pane by spawning `HerdrTerm --bridge --target <pane> …`, which runs `herdr terminal session control <pane> --takeover` and copies `terminal.frame` ANSI bytes into libghostty

Frame / control JSON (Herdr 0.8.2):

- `{ "type": "terminal.frame", "bytes": "<base64>", "encoding": "ansi", "full": true, "width": 80, "height": 24, "seq": 1 }`
- `{ "type": "terminal.input", "bytes": "<base64>" }` or `{ "type": "terminal.input", "text": "..." }` (not both)
- `{ "type": "terminal.resize", "cols": 80, "rows": 24 }`
- `{ "type": "terminal.scroll", "direction": "up" | "down", "lines": 3, "source": "wheel" | "page_key" }`
- `{ "type": "terminal.release" }`

Requests on the API socket are **one-shot**: Herdr answers a single request and closes the connection. Only `events.subscribe` stays open and streams.

v1 shows **one focused pane** at a time. Remote splits still exist on the server; switch panes from the sidebar.

## Shortcuts

| Key | Action |
| --- | --- |
| `⌘K` | Connect… |
| `⌘R` | Reconnect |
| `⌘N` | New window (another host or session) |
| `⌘1`…`⌘9` | Jump to the workspace with that number |
| `⇧⌘U` | Jump to the pane that needs attention |
| `⌃⌘S` | Toggle sidebar |
| `⌃⌘F` | Full screen |

Clicking a pane moves keyboard focus into the terminal; arrow keys browse the sidebar without stealing it. The sidebar is draggable between 180 and 460 pt and its width is remembered.

Scrolling the pane scrolls Herdr's scrollback, not a local copy: the wheel becomes a `terminal.scroll` on the server, which then sends the frame for the new viewport.

## Command line

| Flag | Meaning |
| --- | --- |
| `--connect <host> [--session <name>]` | Open a window straight onto a host |
| `--self-test <host> [--session <name>]` | Connect, snapshot, read one control frame, exit |
| `--bridge --target <pane>` | Internal: the PTY child libghostty spawns for a pane |

## License

MIT. Ghostty/libghostty is MIT. This repo does not vendor [cmux](https://github.com/manaflow-ai/cmux) (AGPL).
