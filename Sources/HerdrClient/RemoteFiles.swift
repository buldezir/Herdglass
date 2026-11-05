import Foundation

/// One entry of a folder on the host, as the Files card's tree shows it.
public struct RemoteFileEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case directory
        case file
        /// A socket, a FIFO, a device, a dangling link: listed, never opened.
        case other
    }

    public var name: String
    public var kind: Kind
    public var isSymlink: Bool

    public init(name: String, kind: Kind, isSymlink: Bool = false) {
        self.name = name
        self.kind = kind
        self.isSymlink = isSymlink
    }

    public var isHidden: Bool { name.hasPrefix(".") }
}

public struct RemoteDirectoryListing: Equatable, Sendable {
    /// Folders first, then names the way the Finder orders them.
    public var entries: [RemoteFileEntry]
    /// The folder had more entries than the listing was allowed to carry.
    public var truncated: Bool
}

/// Every file under a root, for the Files card's fuzzy search.
public struct RemoteFileIndex: Equatable, Sendable {
    /// What listed the files, in the order `RemoteFiles.index` tries them.
    public enum Source: String, Sendable, CaseIterable {
        case fd
        case rg
        case git
        case find
    }

    /// Relative to the root, without a leading `./`, each once.
    public var paths: [String]
    /// The listing ran past the byte cap and the rest was dropped.
    public var truncated: Bool
    public var source: Source

    public init(paths: [String], truncated: Bool, source: Source) {
        self.paths = paths
        self.truncated = truncated
        self.source = source
    }
}

public struct RemoteFileContents: Sendable {
    /// The file's bytes; nil when it is over the read limit and was not sent.
    public var data: Data?
    public var size: Int
    public var writable: Bool
    /// What `cksum` said about the file before it was read. A save hands it
    /// back so the host can refuse to overwrite a file that moved since.
    public var token: String
}

public struct RemoteRoot: Equatable, Sendable {
    public var path: String
    public var home: String

    /// The root as a person would type it: `~/projects/app` rather than the
    /// home directory spelled out.
    public var displayPath: String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// Browse, read and save files on a host through the session's own SSH master.
///
/// Herdr has no file API, and the host may be a box with nothing installed on
/// it but herdr, so this is `bash` and the POSIX tools: no SFTP subsystem, no
/// remote Python. Every script travels to `bash -s` on stdin — argv after the
/// host is joined and re-split by the login shell — and every answer comes
/// back through `base64`, because `ProcessRunner` hands stdout over as a
/// `String` and neither a filename nor a file is obliged to be UTF-8.
public struct RemoteFiles: Sendable {
    public typealias Run = @Sendable (_ script: String, _ timeout: TimeInterval) -> ProcessRunner.Result

    /// Large enough for any source file worth reading in a card, small enough
    /// that a stray click on a log does not pull hundreds of megabytes over SSH.
    public static let readLimit = 4 << 20
    /// A `node_modules` can hold tens of thousands of names, and the tree has
    /// nothing useful to do with them all.
    public static let listLimit = 5_000

    private let run: Run

    public init(run: @escaping Run) {
        self.run = run
    }

    /// Where the card opens: the repository `directory` is in, or `directory`
    /// itself outside one, or the home directory when the pane said nothing.
    public func resolveRoot(from directory: String?) throws -> RemoteRoot {
        let start = directory.flatMap { $0.hasPrefix("/") && !$0.utf8.contains(0) ? $0 : nil } ?? ""
        let result = run("""
        d=\(start.shellEscaped)
        if [ -z "$d" ] || ! cd -- "$d" 2>/dev/null; then cd -- "$HOME"; fi
        root=$(git rev-parse --show-toplevel 2>/dev/null </dev/null || pwd)
        printf '%s\\0%s' "$root" "$HOME" | base64
        """, 15)
        try check(result, action: "Find the folder to show")
        let parts = try decode(result.stdout).split(separator: 0, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let path = String(data: Data(parts[0]), encoding: .utf8), path.hasPrefix("/"),
              let home = String(data: Data(parts[1]), encoding: .utf8)
        else { throw Self.failure("The host returned an invalid folder.") }
        return RemoteRoot(path: path, home: home)
    }

    public func list(_ directory: String, limit: Int = RemoteFiles.listLimit) throws -> RemoteDirectoryListing {
        try validate(directory)
        let result = run("""
        cd -- \(directory.shellEscaped) || exit 3
        shopt -s dotglob nullglob
        n=0
        for e in *; do
          n=$((n + 1))
          if [ "$n" -gt \(limit) ]; then printf 'x/\\0'; break; fi
          if [ -L "$e" ]; then
            if [ -d "$e" ]; then t=l; elif [ -e "$e" ]; then t=s; else t=o; fi
          elif [ -d "$e" ]; then t=d
          elif [ -f "$e" ]; then t=f
          else t=o
          fi
          printf '%s/%s\\0' "$t" "$e"
        done | base64
        """, 15)
        try check(result, action: "List \(directory)")
        return Self.parseListing(try decode(result.stdout))
    }

    /// Every file under `root`, for the fuzzy search, listed by the best tool
    /// the host has: `fd` (`fdfind` on Debian), else `rg --files`, else `git
    /// ls-files` inside a repository, else `find`. The first two are the point —
    /// they honour every `.gitignore` under the root, a repository's own *and*
    /// those of the repositories inside a folder that is not one, so a home
    /// directory's projects arrive without their `build/` and `node_modules`.
    /// Neither is installed on a host that has only herdr, so `git` and `find`
    /// stay behind them, and `find` can only prune by name.
    ///
    /// What each one leaves out is the same: `.git`; outside a repository
    /// hidden folders (hidden files stay — `.env` is something one opens) and
    /// `node_modules`, and in the home directory `~/Library`. Inside one,
    /// hidden folders git tracks (`.github`) are listed, since `.gitignore`
    /// already says what is noise there. Those folders are where the hundreds
    /// of thousands of files are, and none of them is a file anyone means to
    /// open from here.
    ///
    /// The non-interactive PATH an SSH command gets has no Homebrew, cargo or
    /// Nix in it, so their usual homes are searched after it, the way the
    /// bootstrap looks for herdr. `using` skips the choice, for the tests.
    ///
    /// Capped by bytes rather than by count, so the host stops writing — `head`
    /// closes the pipe and the lister dies of it — instead of the cap being
    /// applied here after everything has crossed the link.
    public func index(
        _ root: String,
        using source: RemoteFileIndex.Source? = nil,
        byteLimit: Int = RemoteFiles.indexByteLimit
    ) throws -> RemoteFileIndex {
        try validate(root)
        let result = run("""
        cd -- \(root.shellEscaped) || exit 3
        PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin"
        PATH="$PATH:/home/linuxbrew/.linuxbrew/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin"
        PATH="$PATH:$HOME/.local/share/mise/shims"
        fd=$(command -v fd || command -v fdfind || true)
        rg=$(command -v rg || true)
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1 </dev/null; then repo=1; else repo=; fi
        use=\(source?.rawValue ?? "")
        if [ -z "$use" ]; then
          if [ -n "$fd" ]; then use=fd
          elif [ -n "$rg" ]; then use=rg
          elif [ -n "$repo" ]; then use=git
          else use=find
          fi
        fi
        case "$use" in
          fd) [ -n "$fd" ] || { echo "fd is not installed." >&2; exit 5; } ;;
          rg) [ -n "$rg" ] || { echo "rg is not installed." >&2; exit 5; } ;;
          git) [ -n "$repo" ] || { echo "Not a git repository." >&2; exit 5; } ;;
        esac
        athome=; [ "$PWD" = "$HOME" ] && athome=1
        list() {
          case "$use" in
            fd)
              set -- --exclude .git
              [ -n "$repo" ] || set -- "$@" --exclude '.*/' --exclude 'node_modules/'
              [ -z "$athome" ] || set -- "$@" --exclude '/Library/'
              "$fd" --type f --hidden --no-follow --color never --print0 "$@" ;;
            rg)
              set -- -g '!.git/'
              [ -n "$repo" ] || set -- "$@" -g '!.*/' -g '!node_modules/'
              [ -z "$athome" ] || set -- "$@" -g '!/Library/'
              "$rg" --files --hidden --no-follow --no-messages --null "$@" ;;
            git)
              git ls-files -z --cached --others --exclude-standard ;;
            find)
              set -- -name '.*' -o -name node_modules
              [ -z "$athome" ] || set -- "$@" -o -path ./Library
              find . -xdev -mindepth 1 -type d \\( "$@" \\) -prune -o -type f -print0 ;;
          esac
        }
        printf '%s\\n' "$use"
        list </dev/null 2>/dev/null | head -c \(byteLimit + 1) | base64
        """, 30)
        try check(result, action: "List the files under \(root)")
        let lines = result.stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let used = lines.first.flatMap({ RemoteFileIndex.Source(rawValue: String($0)) }) else {
            throw Self.failure("The host returned an invalid file listing.")
        }
        let listing = try decode(lines.count > 1 ? String(lines[1]) : "")
        return Self.parseIndex(listing, byteLimit: byteLimit, source: used)
    }

    /// About 130,000 paths of a typical length, which is several times any
    /// repository the search is for, and still only a few seconds over SSH.
    public static let indexByteLimit = 8 << 20

    public func read(_ path: String, limit: Int = RemoteFiles.readLimit) throws -> RemoteFileContents {
        try validate(path)
        // The token is taken before the bytes. A write landing between the two
        // then makes the next save refuse a file that has not really moved —
        // which costs a click — rather than overwrite one that has.
        let result = run("""
        f=\(path.shellEscaped)
        if [ ! -f "$f" ]; then echo "Not a file." >&2; exit 3; fi
        if [ ! -r "$f" ]; then echo "Not readable." >&2; exit 3; fi
        size=$(wc -c < "$f" | tr -d ' ')
        if [ -w "$f" ]; then w=w; else w=r; fi
        printf '%s %s\\n' "$size" "$w"
        cksum < "$f"
        if [ "$size" -le \(limit) ]; then head -c \(limit) < "$f" | base64; fi
        """, 30)
        try check(result, action: "Open \((path as NSString).lastPathComponent)")
        return try Self.parseRead(result.stdout, limit: limit)
    }

    /// Write `data` over `path` and answer with the file's new token.
    ///
    /// `token` is the one the file was read with; nil overwrites whatever is
    /// there. The bytes land in a temporary file first and are then copied
    /// over the original with `cat >`, which is local to the host and quick: a
    /// link that drops mid-transfer leaves the file as it was rather than
    /// truncated, and writing *into* the file keeps its inode, mode, owner and
    /// hard links, all of which a `mv` into place would replace.
    @discardableResult
    public func save(_ data: Data, to path: String, expecting token: String?) throws -> String {
        try validate(path)
        let refuseIfMoved = token.map { token in
            """
            if [ "$(cksum < "$f" 2>/dev/null)" != \(token.shellEscaped) ]; then
              echo "The file changed on the host since it was opened." >&2
              exit 4
            fi
            """
        } ?? ""
        let payload = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        // `base64 -d` decodes on GNU and on current macOS; macOS before 13
        // only knew `-D`. Asked once, on a fixed string, because the heredoc
        // can only be read once.
        let result = run("""
        set -e
        f=\(path.shellEscaped)
        if [ ! -f "$f" ]; then echo "Not a file." >&2; exit 3; fi
        \(refuseIfMoved)
        if printf 'YQ==' | base64 -d >/dev/null 2>&1; then decode='base64 -d'; else decode='base64 -D'; fi
        tmp=$(mktemp)
        trap 'rm -f -- "$tmp"' EXIT
        $decode > "$tmp" <<'HERDGLASS_PAYLOAD'
        \(payload)
        HERDGLASS_PAYLOAD
        cat -- "$tmp" > "$f"
        cksum < "$f"
        """, 60)
        if result.terminationStatus == 4 {
            throw HerdrRPCError(code: Self.changedOnHostCode, message: "The file changed on the host since it was opened.")
        }
        try check(result, action: "Save \((path as NSString).lastPathComponent)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let changedOnHostCode = "file_changed"

    public static func isChangedOnHost(_ error: Error) -> Bool {
        (error as? HerdrRPCError)?.code == changedOnHostCode
    }

    // MARK: - Parsing

    static func parseListing(_ data: Data) -> RemoteDirectoryListing {
        var entries: [RemoteFileEntry] = []
        var truncated = false
        for record in data.split(separator: 0) {
            guard record.count >= 2, record[record.startIndex + 1] == UInt8(ascii: "/") else { continue }
            let type = record[record.startIndex]
            if type == UInt8(ascii: "x") {
                truncated = true
                continue
            }
            // A name that is not UTF-8 cannot be shown faithfully, and one shown
            // with replacement characters is a path that names nothing.
            guard let name = String(data: Data(record.dropFirst(2)), encoding: .utf8), !name.isEmpty else { continue }
            switch type {
            case UInt8(ascii: "d"): entries.append(RemoteFileEntry(name: name, kind: .directory))
            case UInt8(ascii: "f"): entries.append(RemoteFileEntry(name: name, kind: .file))
            case UInt8(ascii: "l"): entries.append(RemoteFileEntry(name: name, kind: .directory, isSymlink: true))
            case UInt8(ascii: "s"): entries.append(RemoteFileEntry(name: name, kind: .file, isSymlink: true))
            default: entries.append(RemoteFileEntry(name: name, kind: .other))
            }
        }
        entries.sort { first, second in
            if (first.kind == .directory) != (second.kind == .directory) { return first.kind == .directory }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        return RemoteDirectoryListing(entries: entries, truncated: truncated)
    }

    /// NUL-separated paths. One byte past `byteLimit` says the host had more,
    /// and the record that byte belongs to was cut somewhere in the middle, so
    /// everything after the last NUL inside the limit goes.
    static func parseIndex(_ data: Data, byteLimit: Int, source: RemoteFileIndex.Source) -> RemoteFileIndex {
        var data = data
        let truncated = data.count > byteLimit
        if truncated {
            let kept = data.prefix(byteLimit)
            data = kept.lastIndex(of: 0).map { Data(kept[..<$0]) } ?? Data()
        }
        var seen = Set<String>()
        var paths: [String] = []
        for record in data.split(separator: 0) {
            guard var path = String(data: Data(record), encoding: .utf8) else { continue }
            if path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return RemoteFileIndex(paths: paths, truncated: truncated, source: source)
    }

    static func parseRead(_ output: String, limit: Int) throws -> RemoteFileContents {
        let lines = output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count >= 2 else { throw failure("The host returned an invalid file.") }
        let header = lines[0].split(separator: " ")
        guard header.count == 2, let size = Int(header[0]) else { throw failure("The host returned an invalid file.") }
        let token = lines[1].trimmingCharacters(in: .whitespaces)
        var data: Data?
        if size <= limit {
            guard let decoded = base64(lines.count > 2 ? String(lines[2]) : "") else {
                throw failure("The host returned an invalid file.")
            }
            data = decoded
        }
        return RemoteFileContents(data: data, size: size, writable: header[1] == "w", token: token)
    }

    // MARK: - Helpers

    private func validate(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw Self.failure("Only absolute paths can be opened.")
        }
    }

    private func check(_ result: ProcessRunner.Result, action: String) throws {
        guard result.terminationStatus == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Self.failure("\(action) failed.\(detail.isEmpty ? "" : "\n" + detail)")
        }
    }

    private func decode(_ output: String) throws -> Data {
        guard let data = Self.base64(output) else {
            throw Self.failure("The host returned unreadable output.")
        }
        return data
    }

    /// `base64` of nothing is a bare newline, which Foundation refuses even
    /// with `.ignoreUnknownCharacters` — an empty file or an empty folder would
    /// otherwise read as a corrupt answer.
    private static func base64(_ output: String) -> Data? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Data() : Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters)
    }

    private static func failure(_ message: String) -> HerdrRPCError {
        HerdrRPCError(code: "files_failed", message: message)
    }
}
