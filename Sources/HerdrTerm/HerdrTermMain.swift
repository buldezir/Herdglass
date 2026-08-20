import AppKit
import HerdrClient

@main
enum HerdrTermMain {
    static func main() {
        HerdrProcess.setUp()
        let arguments = Array(CommandLine.arguments.dropFirst())

        // The PTY child libghostty spawns for the focused pane.
        if arguments.contains("--bridge") {
            ControlBridge.run()
            return
        }

        let options = LaunchOptions(arguments: arguments)
        if options.isSelfTest {
            SelfTest.run(host: options.host ?? "local", session: options.session)
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
