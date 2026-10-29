import CryptoKit
import Darwin
import Foundation

/// The herdr a remote host's panes attach with: the release that host's server
/// runs, fetched from herdr's GitHub releases the first time a server on that
/// version is met, and kept in Application Support.
///
/// Attaching is `herdr terminal session control`, which speaks herdr's private
/// terminal protocol to the server, and that has to match the server's exactly
/// (0.8 speaks 20, 0.9 speaks 22). The one herdr certain to speak a server's
/// protocol is that server's own release. Whatever is installed on this Mac is
/// not: it is one version, and the hosts in the sidebar can be on several.
public enum HerdrRelease {
    static let repository = "herdrdev/herdr"

    static var assetName: String {
        #if arch(arm64)
        "herdr-macos-aarch64"
        #else
        "herdr-macos-x86_64"
        #endif
    }

    /// Only a plain release number. The version comes from the server's
    /// snapshot and becomes both a directory and a URL, so anything else —
    /// a preview build, or a server sending `../..` — is refused, not fetched.
    public static func isFetchable(_ version: String) -> Bool {
        version.wholeMatch(of: #/\d+\.\d+\.\d+/#) != nil
    }

    public static var cacheDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Herdglass/herdr", isDirectory: true)
    }

    /// One download at a time: several hosts dial at launch, and two of them on
    /// the same version must not both write it.
    private static let lock = NSLock()

    /// The path of herdr `version`, downloading it first if it is not here yet.
    public static func binary(version: String) throws -> String {
        guard isFetchable(version) else {
            throw HerdrRPCError(
                code: "herdr_release",
                message: "herdr \(version.isEmpty ? "(no version)" : version) is not a release Herdglass can fetch"
            )
        }
        lock.lock()
        defer { lock.unlock() }

        let directory = cacheDirectory.appendingPathComponent(version, isDirectory: true)
        let binary = directory.appendingPathComponent("herdr")
        if FileManager.default.isExecutableFile(atPath: binary.path), reportsVersion(version, at: binary.path) {
            return binary.path
        }

        let (url, sha256) = try asset(named: assetName, inRelease: try fetch(releaseRequest(version)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent("herdr.download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: partial) }
        try download(url, to: partial)

        let data = try Data(contentsOf: partial, options: .alwaysMapped)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else {
            throw HerdrRPCError(
                code: "herdr_release",
                message: "the download of herdr \(version) does not match the checksum GitHub publishes for it"
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: partial.path)
        guard reportsVersion(version, at: partial.path) else {
            throw HerdrRPCError(code: "herdr_release", message: "the downloaded herdr \(version) does not run on this Mac")
        }
        // Atomic, so a bridge never starts a half-written binary.
        guard rename(partial.path, binary.path) == 0 else {
            throw HerdrRPCError(code: "herdr_release", message: "could not keep herdr \(version): \(String(cString: strerror(errno)))")
        }
        return binary.path
    }

    /// The download URL and SHA-256 of one asset, from GitHub's description of
    /// a release. A release without a digest is refused: nothing this app has
    /// not checked gets run.
    public static func asset(named name: String, inRelease data: Data) throws -> (url: URL, sha256: String) {
        let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let assets = release?["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { $0["name"] as? String == name }) else {
            throw HerdrRPCError(code: "herdr_release", message: "the release has no \(name)")
        }
        guard
            let link = asset["browser_download_url"] as? String,
            let url = URL(string: link),
            url.scheme == "https"
        else {
            throw HerdrRPCError(code: "herdr_release", message: "the release's \(name) has no download link")
        }
        guard
            let digest = asset["digest"] as? String,
            digest.hasPrefix("sha256:"),
            case let hex = digest.dropFirst("sha256:".count).lowercased(),
            hex.wholeMatch(of: #/[0-9a-f]{64}/#) != nil
        else {
            throw HerdrRPCError(code: "herdr_release", message: "GitHub publishes no checksum for the release's \(name)")
        }
        return (url, hex)
    }

    static func releaseRequest(_ version: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/tags/v\(version)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Herdglass", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private static func reportsVersion(_ version: String, at path: String) -> Bool {
        let status = ProcessRunner.run(executable: path, arguments: ["status", "client"], extraEnv: [:], timeout: 5)
        return status.terminationStatus == 0 && HerdrStatus.client(at: path, from: status.stdout).version == version
    }

    // MARK: - Network

    /// The proxy settings and timeouts of the system, not of `curl`: a GUI app
    /// behind a corporate proxy only has the former.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    private static func fetch(_ request: URLRequest) throws -> Data {
        let outcome = Outcome<Data>()
        session.dataTask(with: request) { data, response, error in
            outcome.finish(Result {
                try check(response, error, for: request.url)
                return data ?? Data()
            })
        }.resume()
        return try outcome.wait()
    }

    private static func download(_ url: URL, to destination: URL) throws {
        let outcome = Outcome<Void>()
        session.downloadTask(with: url) { location, response, error in
            // The temporary file is gone once this returns, so move it now.
            outcome.finish(Result {
                try check(response, error, for: url)
                guard let location else { throw URLError(.cannotOpenFile) }
                try FileManager.default.moveItem(at: location, to: destination)
            })
        }.resume()
        try outcome.wait()
    }

    private static func check(_ response: URLResponse?, _ error: Error?, for url: URL?) throws {
        if let error { throw error }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw HerdrRPCError(
                code: "herdr_release",
                message: "\(url?.host ?? "GitHub") answered HTTP \(status) for \(url?.path ?? "the release")"
            )
        }
    }
}

/// A completion handler's result, handed to a thread that is waiting for it.
private final class Outcome<Value>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func finish(_ result: Result<Value, Error>) {
        self.result = result
        done.signal()
    }

    func wait() throws -> Value {
        done.wait()
        return try result!.get()
    }
}
