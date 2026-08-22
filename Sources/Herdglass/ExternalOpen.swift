import AppKit

extension NSWorkspace {
    /// Hand a URL to LaunchServices, and leave something to read when it says no.
    ///
    /// `open(_:)` answers with a `Bool` that is easy to drop, and a refusal
    /// reaches the user as one of LaunchServices' own dialogs — "The
    /// application can't be opened. -50" when it cannot launch the handler for
    /// the scheme — which names neither the URL nor the app that asked for it.
    /// The async form carries the real `NSError`, so a link that goes nowhere
    /// says so on stderr, where `Scripts/dev.sh --run` shows it.
    ///
    /// `/usr/bin/open` is then a second attempt from a process of its own. It
    /// fails the same way when the handler is genuinely broken, and its own
    /// complaint lands on the stderr it inherits, but it gets the link open in
    /// the cases where only this process's view of LaunchServices was wedged.
    func openExternally(_ url: URL) {
        open(url, configuration: OpenConfiguration()) { _, error in
            guard let error else { return }
            let code = (error as NSError).code
            FileHandle.standardError.write(Data(
                "Could not open \(url.absoluteString): \(error.localizedDescription) (\(code)). Retrying with /usr/bin/open.\n".utf8
            ))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.absoluteString]
            do {
                try process.run()
            } catch {
                FileHandle.standardError.write(Data(
                    "Could not run /usr/bin/open for \(url.absoluteString): \(error.localizedDescription)\n".utf8
                ))
            }
        }
    }
}
