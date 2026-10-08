import Foundation

/// Transfer one item at a time through tar into a private staging directory,
/// then publish it in the pane's cwd. No scp/SFTP server or remote Python needed.
enum FileUpload {
    typealias Run = ([String], String?, URL?) -> ProcessRunner.Result

    static func upload(files: [URL], to directory: String, run: Run) throws -> [String] {
        guard directory.hasPrefix("/"), !directory.utf8.contains(0) else {
            throw failure("The pane did not report an absolute current directory.")
        }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("herdglass-upload-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("upload.tar")
        var paths: [String] = []
        for file in files {
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            guard file.isFileURL, !file.lastPathComponent.isEmpty, file.path != "/" else {
                throw failure("Only files and folders can be uploaded.")
            }
            let name = file.lastPathComponent
            let packed = ProcessRunner.run(
                executable: "/usr/bin/tar",
                arguments: ["-cf", archive.path, "-C", file.deletingLastPathComponent().path, "./" + name],
                extraEnv: ["COPYFILE_DISABLE": "1"], timeout: 300
            )
            try check(packed, action: "Read \(name)")

            let stageName = ".herdglass-upload-\(UUID().uuidString)"
            let prepared = run(["bash", "-s"], """
            set -e
            cd -- \(directory.shellEscaped)
            umask 077
            mkdir -- \(stageName.shellEscaped)
            printf '%s' "$PWD/\(stageName)" | base64
            """, nil)
            try check(prepared, action: "Prepare upload directory")
            let stage = try decodePath(prepared.stdout)
            defer {
                _ = run(["bash", "-s"], "rm -rf -- \(stage.shellEscaped)\n", nil)
            }
            try check(run(["tar", "-xf", "-", "-C", stage], nil, archive), action: "Upload \(name)")
            let published = run(["bash", "-s"], """
            set -e
            cd -- \(directory.shellEscaped)
            name=\(name.shellEscaped)
            source=\((stage + "/" + name).shellEscaped)
            stem="$name"
            extension=""
            if [[ "$name" == *.* && "$name" != .* ]]; then
              stem="${name%.*}"
              extension=".${name##*.}"
            fi
            candidate="$name"
            number=1
            while [ -e "$source" ] || [ -L "$source" ]; do
              if [ -e "$candidate" ] || [ -L "$candidate" ]; then
                number=$((number + 1))
                candidate="$stem ($number)$extension"
                continue
              fi
              mv -n -- "$source" "$candidate"
            done
            printf '%s' "$PWD/$candidate" | base64
            """, nil)
            try check(published, action: "Save \(name)")
            paths.append(try decodePath(published.stdout))
        }
        return paths
    }

    private static func check(_ result: ProcessRunner.Result, action: String) throws {
        guard result.terminationStatus == 0 else {
            let detail = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure("\(action) failed.\(detail.isEmpty ? "" : "\n" + detail)")
        }
    }

    private static func decodePath(_ output: String) throws -> String {
        guard let data = Data(base64Encoded: output, options: .ignoreUnknownCharacters),
              let path = String(data: data, encoding: .utf8), path.hasPrefix("/"), !path.utf8.contains(0)
        else { throw failure("The host returned an invalid upload path.") }
        return path
    }

    private static func failure(_ message: String) -> HerdrRPCError {
        HerdrRPCError(code: "upload_failed", message: message)
    }
}

public enum PaneUpload: Sendable {
    case files([URL])
    case image(Data)

    public var count: Int {
        switch self {
        case .files(let files): return files.count
        case .image: return 1
        }
    }

    public func upload(using connection: RemoteConnection, to directory: String) throws -> [String] {
        switch self {
        case .files(let files):
            return try connection.upload(files: files, to: directory)
        case .image(let data):
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdglass-image-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("pasted-image-\(UUID().uuidString.prefix(8)).png")
            try data.write(to: file)
            return try connection.upload(files: [file], to: directory)
        }
    }

    /// Paths become editable input, never an executed command. Keep shell
    /// metacharacters and embedded newlines inside a quoted argument.
    public static func pastedPaths(_ paths: [String]) -> String {
        paths.map { path in
            path.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "/._-+").union(.alphanumerics).contains($0) }
                ? path : path.shellEscaped
        }.joined(separator: " ") + " "
    }
}
