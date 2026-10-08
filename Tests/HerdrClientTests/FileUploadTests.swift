import Foundation
import Testing
@testable import HerdrClient

private func uploadFixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdglass-upload-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

private func localUploadCommand(_ arguments: [String], _ script: String?, _ archive: URL?) -> ProcessRunner.Result {
    ProcessRunner.run(executable: arguments[0] == "bash" ? "/bin/bash" : "/usr/bin/tar",
                      arguments: Array(arguments.dropFirst()), extraEnv: ["COPYFILE_DISABLE": "1"],
                      stdin: script, stdinFile: archive, timeout: 5)
}

@Suite(.serialized)
struct FileUploadTests {

    @Test func uploadCommandsSurviveSSHJoiningArgumentsThroughZsh() throws {
        let root = try uploadFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("server directory ' ; $(touch injected)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("image ' with spaces.png")
        try Data([0, 255, 1]).write(to: file)
        let paths = try FileUpload.upload(files: [file], to: destination.path) { arguments, script, archive in
            ProcessRunner.run(executable: "/bin/zsh", arguments: ["-c", arguments.map(\.shellEscaped).joined(separator: " ")],
                              extraEnv: [:], stdin: script, stdinFile: archive, timeout: 5)
        }
        #expect(paths.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == Data([0, 255, 1]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [file.lastPathComponent])
    }

    @Test func uploadPreservesBinaryDataAndShellMetacharactersInPaths() throws {
        let root = try uploadFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination ' $(touch injected);\nwith space")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("-a ' $(touch injected);\n画像.bin")
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: file)
        let connection = try RemoteConnection(target: ConnectTarget(host: "local"))
        defer { connection.close() }
        let paths = try connection.upload(files: [file], to: destination.path)
        #expect(paths.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == bytes)
        #expect((paths[0] as NSString).lastPathComponent == file.lastPathComponent)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [file.lastPathComponent])
    }

    @Test func uploadKeepsExistingFilesAndChoosesNumberedNames() throws {
        let root = try uploadFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.png")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: source)
        let original = destination.appendingPathComponent("image.png")
        try Data("original".utf8).write(to: original)
        let reserved = destination.appendingPathComponent("image (2).png")
        try FileManager.default.createSymbolicLink(atPath: reserved.path, withDestinationPath: "missing-target")
        let paths = try FileUpload.upload(files: [source, source], to: destination.path, run: localUploadCommand)
        #expect(paths.map { ($0 as NSString).lastPathComponent } == ["image (3).png", "image (4).png"])
        #expect(try Data(contentsOf: original) == Data("original".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: reserved.path) == "missing-target")
        for path in paths { #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("new".utf8)) }
    }

    @Test func uploadCopiesFoldersWithoutMergingWithAnExistingFolder() throws {
        let root = try uploadFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("folder/subfolder")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data([0, 1, 255]).write(to: source.appendingPathComponent("nested.bin"))
        let paths = try FileUpload.upload(files: [source.deletingLastPathComponent()], to: destination.path, run: localUploadCommand)
        #expect((paths[0] as NSString).lastPathComponent == "folder (2)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0]).appendingPathComponent("subfolder/nested.bin")) == Data([0, 1, 255]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("folder").path).isEmpty)
    }

    @Test func uploadFailureRemovesStagingAndDoesNotPublishPartialFiles() throws {
        let root = try uploadFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.bin")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: source)
        #expect(throws: HerdrRPCError.self) {
            try FileUpload.upload(files: [source], to: destination.path) { arguments, script, archive in
                let result = localUploadCommand(arguments, script, archive)
                if arguments[0] == "tar" {
                    return ProcessRunner.Result(terminationStatus: 1, stdout: "", stderr: "transfer interrupted")
                }
                return result
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func uploadRejectsAnUnknownDirectoryAndAClosedConnection() throws {
        let root = try uploadFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.bin")
        try Data([1]).write(to: source)
        let connection = try RemoteConnection(target: ConnectTarget(host: "local"))
        #expect(throws: HerdrRPCError.self) { try connection.upload(files: [source], to: "relative") }
        connection.close()
        #expect(throws: HerdrRPCError.self) { try connection.upload(files: [source], to: root.path) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["input.bin"])
    }

    @Test func pastedImageUploadsAsAPNGWithItsBytesIntact() throws {
        let destination = try uploadFixture()
        defer { try? FileManager.default.removeItem(at: destination) }
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let connection = try RemoteConnection(target: ConnectTarget(host: "local"))
        defer { connection.close() }
        let paths = try PaneUpload.image(data).upload(using: connection, to: destination.path)
        #expect(paths.count == 1)
        #expect(paths[0].hasSuffix(".png"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == data)
    }

    @Test func pastedPathsRemainSeparateShellArgumentsWithoutExecutingTheirContents() throws {
        let paths = ["/tmp/simple.png", "/tmp/a ' $(echo injected);\n图像.png", "/tmp/one two"]
        let result = ProcessRunner.run(
            executable: "/bin/bash", arguments: ["-s"], extraEnv: [:],
            stdin: "set -- " + PaneUpload.pastedPaths(paths) + "\nfor path in \"$@\"; do printf '%s' \"$path\" | base64 | tr -d '\\n'; printf '\\n'; done\n",
            timeout: 5
        )
        #expect(result.terminationStatus == 0)
        let decoded = result.stdout.split(separator: "\n").compactMap { Data(base64Encoded: String($0)).flatMap { String(data: $0, encoding: .utf8) } }
        #expect(decoded == paths)
    }

    @Test func processRunnerStreamsFileInputLargerThanAPipeBuffer() throws {
        let root = try uploadFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.bin")
        try Data(repeating: 255, count: 1_000_000).write(to: file)
        let result = ProcessRunner.run(executable: "/usr/bin/wc", arguments: ["-c"], extraEnv: [:], stdinFile: file, timeout: 5)
        #expect(result.terminationStatus == 0)
        #expect(Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == 1_000_000)
    }

    @Test func uploadDirectoryPrefersTheForegroundProcessAndFallsBackToTheShell() throws {
        let data = Data("""
        {"pane_id":"w1:p1","terminal_id":"t","workspace_id":"w1","tab_id":"w1:t1",
         "focused":true,"agent_status":"idle","revision":1,"cwd":"/shell","foreground_cwd":"/agent"}
        """.utf8)
        var pane = try JSONDecoder().decode(PaneInfo.self, from: data)
        #expect(pane.currentDirectory == "/agent")
        pane.foregroundCwd = ""
        #expect(pane.currentDirectory == "/shell")
        pane.cwd = nil
        #expect(pane.currentDirectory == nil)
    }
}
