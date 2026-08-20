import Foundation

public enum SSHConfig {
    public static func hostAliases(from contents: String? = nil) -> [String] {
        let text: String
        if let contents {
            text = contents
        } else {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/config")
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        var hosts: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            // ssh_config accepts `Host a b`, `Host\ta` and `Host=a` alike.
            guard let separator = line.firstIndex(where: { $0.isWhitespace || $0 == "=" }),
                  line[..<separator].lowercased() == "host"
            else { continue }
            let rest = line[line.index(after: separator)...]
            for token in rest.split(whereSeparator: { $0.isWhitespace || $0 == "=" }) {
                let name = String(token)
                // Patterns and negations are not connectable destinations.
                if name.contains("*") || name.contains("?") || name.hasPrefix("!") { continue }
                if !hosts.contains(name) { hosts.append(name) }
            }
        }
        return hosts
    }
}

public struct SSHTarget: Sendable {
    public var destination: String
    public var extraArgs: [String]

    public init(host: String) {
        if host.hasPrefix("ssh://") {
            let trimmed = String(host.dropFirst(6))
            var user: String?
            var hostname = trimmed
            var port: String?
            if let at = trimmed.firstIndex(of: "@") {
                user = String(trimmed[..<at])
                hostname = String(trimmed[trimmed.index(after: at)...])
            }
            if let colon = hostname.lastIndex(of: ":"),
               hostname[hostname.index(after: colon)...].allSatisfy(\.isNumber)
            {
                port = String(hostname[hostname.index(after: colon)...])
                hostname = String(hostname[..<colon])
            }
            extraArgs = []
            if let port { extraArgs += ["-p", port] }
            if let user {
                destination = "\(user)@\(hostname)"
            } else {
                destination = hostname
            }
        } else {
            destination = host
            extraArgs = []
        }
    }
}
