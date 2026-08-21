import AppKit
import HerdrClient

@main
enum HerdglassMain {
    static func main() {
        HerdrProcess.setUp()
        let arguments = Array(CommandLine.arguments.dropFirst())

        // The PTY child libghostty spawns for the focused pane.
        if arguments.contains("--bridge") {
            ControlBridge.run(arguments: arguments)
            return
        }

        // What the app took from `~/.config/ghostty/config`; the counterpart to
        // `ghostty +show-config`, and the quickest way to see whether a key we
        // honour actually arrived.
        if arguments.contains("--show-ghostty-config") {
            MainActor.assumeIsolated {
                // The menu is built for real, so the dump shows the shortcuts
                // the app will actually have, not just the ones we read.
                _ = NSApplication.shared
                let config = GhosttyRuntime.config
                let menu = MainMenu.build()
                menu.applyGhosttyShortcuts(config)
                print(config.summary)
                print("menu")
                print(menu.shortcutSummary(config))
            }
            return
        }

        let options = LaunchOptions(arguments: arguments)
        if options.isSelfTest {
            SelfTest.run(host: options.host ?? "local", session: options.session)
            return
        }

        // One instance, and it is the one already on screen.
        //
        // The Finder refuses a second launch of a bundle on its own, but
        // `open -n` and the binary run straight out of `.build` — which is how
        // this app is started every time it is worked on — do not. Two
        // instances is not a cosmetic problem: both restore the same attached
        // hosts, so every host ends up with two SSH masters and two sets of
        // bridges for the same panes, and the two disagree about what Herdr
        // last said.
        //
        // The `--bridge` children exec this same binary and have returned long
        // before this line. They never build an `NSApplication`, so
        // LaunchServices does not register them and they can never be mistaken
        // for a second app.
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.herdr.term")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            running.activate()
            let ignored = options.target.map { " Ignoring --connect \($0.displayName)." } ?? ""
            FileHandle.standardError.write(Data(
                "Herdglass is already running (pid \(running.processIdentifier)); brought it to the front.\(ignored)\n".utf8
            ))
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(initialTarget: options.target)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

/// `--connect <host>` / `--self-test <host>` / `--session <name>`.
/// Host is the optional value right after the flag, like `herdr --remote`.
struct LaunchOptions {
    var host: String?
    var session: String?
    var isSelfTest = false

    var target: ConnectTarget? {
        host.map { ConnectTarget(host: $0, session: session) }
    }

    init(arguments: [String]) {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let value = arguments.indices.contains(index + 1) && !arguments[index + 1].hasPrefix("--")
                ? arguments[index + 1]
                : nil
            switch argument {
            case "--self-test":
                isSelfTest = true
                host = value ?? host
            case "--connect":
                host = value ?? host
            case "--session":
                session = value
            default:
                index += 1
                continue
            }
            index += value == nil ? 1 : 2
        }
    }
}
